import Foundation
import Darwin

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    /// The bounded, redacted tail of merged stdout and stderr.
    public let output: String
    public init(exitCode: Int32, output: String) { self.exitCode = exitCode; self.output = output }
}

/// Every command owns a POSIX process group. Cancellation reaches the compiler and other descendants,
/// including tools that ignore SIGTERM. Arguments never pass through a shell.
public final class ProcessRunner: @unchecked Sendable {
    private struct Active { var token: UUID; var pid: pid_t?; var cancelled: Bool }
    private let lock = NSLock()
    private var active: Active?
    public init() {}

    public func run(_ command: ProcessCommand,
                    onLine: @Sendable @escaping (String) -> Void = { _ in }) async throws -> ProcessResult {
        let token = UUID()
        try lock.withLock {
            guard active == nil else { throw PortError.processAlreadyRunning }
            active = Active(token: token, pid: nil, cancelled: false)
        }
        return try await withTaskCancellationHandler {
            if Task.isCancelled { cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try self.execute(command, token: token, onLine: onLine)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }

    public func cancel() {
        let state: Active? = lock.withLock {
            guard var current = active else { return nil }
            current.cancelled = true; active = current; return current
        }
        guard let state, let pid = state.pid else { return }
        kill(-pid, SIGTERM)
        // A compiler can ignore SIGTERM; its group must not outlive a cancelled port build.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let stillActive = self.lock.withLock { self.active?.token == state.token }
            if stillActive { kill(-pid, SIGKILL) }
        }
    }

    /// Use from applicationWillTerminate: the application may exit before a delayed escalation runs.
    public func cancelImmediately() {
        let pid: pid_t? = lock.withLock {
            guard var current = active else { return nil }
            current.cancelled = true; active = current
            return current.pid
        }
        if let pid { kill(-pid, SIGKILL) }
    }

    private func execute(_ command: ProcessCommand, token: UUID,
                         onLine: @Sendable (String) -> Void) throws -> ProcessResult {
        defer { lock.withLock { if active?.token == token { active = nil } } }
        if lock.withLock({ active?.cancelled == true }) { throw CancellationError() }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw PortError.launchFailed("Could not create the process output pipe.") }
        var actions: posix_spawn_file_actions_t?
        var attrs: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attrs)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attrs) }
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawn_file_actions_addclose(&actions, descriptors[1])
        // A GUI command must never wait for an invisible stdin prompt.
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        if let directory = command.workingDirectoryURL {
            let status: Int32
            if #available(macOS 26, *) {
                status = posix_spawn_file_actions_addchdir(&actions, directory.path)
            } else {
                status = posix_spawn_file_actions_addchdir_np(&actions, directory.path)
            }
            if status != 0 { close(descriptors[0]); close(descriptors[1]); throw PortError.launchFailed("Invalid working directory: \(status)") }
        }
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attrs, 0)
        let args = ([command.executableURL.path] + command.arguments).map { strdup($0) }
        var argv = args + [nil]
        var environment = ToolEnvironment.values
        environment.merge(command.environment) { _, new in new }
        let envStrings = environment.map { strdup("\($0.key)=\($0.value)") }
        var envp = envStrings + [nil]
        defer { args.forEach { free($0) }; envStrings.forEach { free($0) } }
        var pid: pid_t = 0
        // Serialize launch with cancellation. A synchronous termination callback either prevents
        // the spawn or sees its PID, so it cannot leave a compiler behind during application exit.
        let spawned: Int32 = lock.withLock {
            guard active?.token == token, active?.cancelled != true else { return ECANCELED }
            let status = posix_spawn(&pid, command.executableURL.path, &actions, &attrs, &argv, &envp)
            if status == 0 { active?.pid = pid }
            return status
        }
        close(descriptors[1])
        guard spawned == 0 else {
            close(descriptors[0])
            if spawned == ECANCELED { throw CancellationError() }
            throw PortError.launchFailed("Could not launch \(command.executableURL.lastPathComponent): \(String(cString: strerror(spawned)))")
        }
        let cancelled = lock.withLock {
            return active?.cancelled == true
        }
        if cancelled { cancel() }
        defer { close(descriptors[0]) }
        var pending = Data(), retained = ""
        let retainLimit = 2_000_000
        func emit(_ data: Data) {
            let line = LogRedactor.clean(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            retained += line + "\n"
            if retained.utf8.count > retainLimit { retained = String(retained.suffix(retainLimit / 2)) }
            onLine(line)
        }
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while true {
            // FileHandle.read(upToCount:) can wait to fill its requested length on a pipe.
            // read(2) returns the currently available bytes, so progress arrives while work runs.
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptors[0], $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                kill(-pid, SIGKILL)
                break
            }
            if count == 0 { break }
            let data = Data(buffer.prefix(count))
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                emit(pending[..<end]); pending.removeSubrange(...end)
            }
            // Do not allow a broken tool's newline-free output to consume unbounded memory.
            if pending.count > 1_000_000 { emit(pending); pending.removeAll(keepingCapacity: true) }
        }
        if !pending.isEmpty { emit(pending) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        if lock.withLock({ active?.cancelled == true }) {
            // A descendant may redirect its output and remain alive after the parent exits.
            // Finish the group even when EOF arrives before the delayed escalation.
            kill(-pid, SIGKILL)
            throw CancellationError()
        }
        let signal = status & 0x7f
        let exitCode = signal == 0 ? ((status >> 8) & 0xff) : 128 + signal
        return ProcessResult(exitCode: exitCode, output: retained)
    }
}

public enum LogRedactor {
    public static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "(?i)\\b([a-z0-9_]*(?:key|kek)[a-z0-9_]*)\\s*=\\s*[0-9a-f]{16,}",
                                  with: "$1 = [redacted]", options: .regularExpression)
    }
}
