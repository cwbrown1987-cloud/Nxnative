// Runs scripts/build_ipa_from_nsp.py --platform mac-app --progress json and follows its events
// (stage, step, progress, stage_end, say: docs/development.md), then checks the app's signature.
import Foundation
import Observation

struct Job {
    var gameDir: String
    var keys: String
    var sign: String?
    var env: ToolEnv
    /// Rebuild this app in place: it is moved to app-backups/ first and put back if the build fails.
    var rebuild: String?
    /// where the app goes (-o); nil = <game name>.app in the game folder
    var out: String?
    /// false: the replaced app goes to the Trash once the new one is built, not to app-backups/
    var keepBackup = true
    /// false: delete the stage keys in <id>_build first, so every step runs again
    var reuseCache = true
}

struct Stage: Hashable {
    var k = 0, n = 0
    var name = "", step = ""
    var fraction: Double?
    var detail = ""
}

struct StageDone: Hashable, Identifiable {
    var id: Int { k }
    let k: Int, n: Int
    let name: String
    let ok: Bool
    let seconds: Int
    let summary: String

    var reused: Bool { summary.contains("reused") }
    var line: String {
        "[\(k)/\(n)] \(name) (\(seconds / 60):\(String(format: "%02d", seconds % 60)))" + (summary.isEmpty ? "" : ": \(summary)")
    }
}

@MainActor @Observable
final class BuildRun {
    var running = false
    var stage = Stage()
    var done: [StageDone] = []
    var log: [String] = []
    var app: String?
    var backup: String?
    var result: Result<String, ConverterError>?
    private var process: Process?
    /// called on the main thread after each change (the command line prints from it)
    var onChange: (() -> Void)?

    func start(_ job: Job) {
        running = true; stage = Stage(); done = []; log = []; app = nil; backup = nil; result = nil
        Thread.detachNewThread { [weak self] in
            let r = Self.perform(job, run: self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                self.process = nil
                self.result = r
                self.onChange?()
            }
        }
    }

    /// Ask the script to stop as Ctrl-C would (it ends the stage and exits with 130).
    func cancel() { process?.interrupt() }

    private func main(_ f: @escaping @MainActor (BuildRun) -> Void) {
        DispatchQueue.main.async { f(self); self.onChange?() }
    }

    nonisolated private static func perform(_ job: Job, run r: BuildRun?) -> Result<String, ConverterError> {
        guard let r else { return .failure(ConverterError("cancelled")) }
        let say: (String) -> Void = { m in DispatchQueue.main.async { r.log.append(m); r.onChange?() } }
        do {
            let lock = try FolderLock(job.gameDir)
            defer { lock.release() }
            guard let repo = job.env.repo else { throw ConverterError("no nxnative repository") }
            guard let engine = Engine.current(repo) else { throw ConverterError("cannot read the engine's git commit") }
            var backup: String?
            if let app = job.rebuild {
                let old = Engine.builds().first { $0.app == app }?.engine
                let b = try Engine.backUp(app, engine: old)
                backup = b
                say("old app moved to \(b)")
                DispatchQueue.main.async { r.backup = b }
            }
            if !job.reuseCache { forgetStageKeys(job.gameDir); say("cached build steps cleared: every step runs again") }
            do {
                let app = try build(job, repo: repo, run: r)
                let (steps, shaders) = DispatchQueue.main.sync { (r.done.filter(\.ok).count, r.done.first { $0.name.hasPrefix("Mac shaders") }.flatMap(shaderCount)) }
                Engine.record(BuildRecord(app: app, gameDir: job.gameDir, engine: engine, repo: repo, builtAt: Engine.now(), steps: steps, shaders: shaders,
                                          gameFiles: Engine.describeFiles(job.gameDir)))
                let msg = try verify(app)
                if let b = backup, !job.keepBackup, (try? FileManager.default.trashItem(at: b.url, resultingItemURL: nil)) != nil {
                    say("old app moved to the Trash")
                    DispatchQueue.main.async { r.backup = nil }
                }
                return .success(msg)
            } catch {
                // keep a working game: put the old app back unless the failed build left something in its place
                if let b = backup, let app = job.rebuild, !FileManager.default.fileExists(atPath: app), (try? FileManager.default.moveItem(atPath: b, toPath: app)) != nil {
                    say("build failed: the old app is back at \(app)")
                    DispatchQueue.main.async { r.backup = nil }
                }
                throw error
            }
        } catch let e as ConverterError {
            return .failure(e)
        } catch {
            return .failure(ConverterError("\(error)"))
        }
    }

    /// The stage keys (sha256 of each stage's inputs, <id>_build/**/*.key) that let the script reuse a stage.
    nonisolated private static func forgetStageKeys(_ dir: String) {
        let fm = FileManager.default
        for b in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter({ $0.hasSuffix("_build") }) {
            let root = "\(dir)/\(b)"
            for case let rel as String in fm.enumerator(atPath: root) ?? NSEnumerator() where rel.hasSuffix(".key") && !rel.hasPrefix("extract/") {
                try? fm.removeItem(atPath: "\(root)/\(rel)")
            }
        }
    }

    /// "12,691 of 12,691 shaders ready, reused" → "12,691"
    nonisolated static func shaderCount(_ s: StageDone) -> String? {
        guard let r = s.summary.range(of: " shaders ready") else { return nil }
        return s.summary[..<r.lowerBound].components(separatedBy: " of ").last
    }

    nonisolated private static func build(_ job: Job, repo: String, run r: BuildRun) throws -> String {
        guard let py = job.env.python else { throw ConverterError("no Python with the script's modules") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        var args = ["-u", repo + "/" + scriptPath, job.gameDir, "-k", job.keys, "--platform", "mac-app", "--progress", "json"]
        if let id = job.sign { args += ["--mac-sign", id] }
        if let o = job.rebuild ?? job.out { args += ["-o", o] }
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = job.env.path
        env["PYTHONUNBUFFERED"] = "1"
        if env["DOTNET_ROOT"] == nil, let d = job.env.dotnetRoot { env["DOTNET_ROOT"] = d }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { throw ConverterError("cannot start \(py): \(error.localizedDescription)") }
        DispatchQueue.main.async { r.process = p }

        let errDone = DispatchSemaphore(value: 0)
        var errLines: [String] = []
        Thread.detachNewThread {
            for l in Lines(err.fileHandleForReading) { errLines.append(l); DispatchQueue.main.async { r.log.append(l) } }
            errDone.signal()
        }
        var appPath: String?
        for line in Lines(out.fileHandleForReading) {
            if let a = event(line, run: r) { appPath = a }
        }
        p.waitUntilExit()
        errDone.wait()
        switch p.terminationStatus {
        case 0: break
        case 130: throw ConverterError("stopped")
        default:
            // the script's own last red line, which names the failed step and its log
            let red = DispatchQueue.main.sync { r.log.last { $0.contains("[RED]") } } ?? errLines.last
            throw ConverterError(red ?? "the script exited with \(p.terminationStatus)")
        }
        guard let appPath else { throw ConverterError("the script finished but named no app") }
        DispatchQueue.main.async { r.app = appPath }
        return appPath
    }

    /// One stdout line of the script; returns the app's path from its "done: <path>.app (…)" message.
    nonisolated private static func event(_ line: String, run r: BuildRun) -> String? {
        guard let v = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let ev = v["ev"] as? String else {
            DispatchQueue.main.async { r.log.append(line); r.onChange?() }
            return nil
        }
        let str = { (k: String) in v[k] as? String ?? "" }
        let num = { (k: String) in (v[k] as? NSNumber)?.doubleValue }
        var app: String?
        if ev == "say", let msg = v["msg"] as? String, let i = msg.range(of: "done: "), let j = msg[i.upperBound...].range(of: ".app") {
            app = String(msg[i.upperBound..<j.upperBound])
        }
        DispatchQueue.main.async {
            switch ev {
            case "stage":
                r.stage = Stage(k: Int(num("k") ?? 0), n: Int(num("n") ?? 0), name: str("name"), step: str("step"))
            case "step":
                r.stage.step = str("step")
            case "progress":
                r.stage.step = str("step")
                r.stage.fraction = num("frac")
                var d = ""
                if let done = num("done"), let total = num("total") {
                    let est = (v["est"] as? Bool) == true ? "~" : ""
                    d = str("unit") == "B" ? String(format: "%.1f/%@%.1f GB", done / 1e9, est, total / 1e9) : "\(Int(done))/\(est)\(Int(total)) \(str("unit"))"
                }
                if let eta = num("eta") { d += String(format: " · ETA %d:%02d", Int(eta) / 60, Int(eta) % 60) }
                r.stage.detail = d
            case "stage_end":
                r.done.append(StageDone(k: r.stage.k, n: r.stage.n, name: r.stage.name, ok: (v["ok"] as? Bool) ?? true, seconds: Int(num("elapsed") ?? 0), summary: str("summary")))
                r.stage.fraction = 1
            case "say":
                r.log += str("msg").split(separator: "\n").map(String.init)
            default:
                r.log.append(line)
            }
            r.onChange?()
        }
        return app
    }

    /// The app must be a bundle with an executable launcher and a valid signature.
    nonisolated static func verify(_ app: String) throws -> String {
        let exe = app + "/Contents/MacOS/nxnative"
        guard FileManager.default.isExecutableFile(atPath: exe) else { throw ConverterError("\(app) has no executable launcher") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--verify", "--deep", "--strict", app]
        let e = Pipe()
        p.standardError = e
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw ConverterError("signature check failed: " + String(decoding: e.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // codesign -dv writes to stderr
        let d = Process()
        d.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        d.arguments = ["-dv", app]
        let de = Pipe()
        d.standardError = de
        d.standardOutput = Pipe()
        try d.run()
        let info = String(decoding: de.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        d.waitUntilExit()
        let signer = info.split(separator: "\n").first { $0.hasPrefix("Authority=") }.map { String($0.dropFirst(10)) } ?? (info.contains("Signature=adhoc") ? "ad-hoc" : "unknown")
        return "\(app) is signed (\(signer)) and the signature verifies"
    }
}

/// One build per game folder at a time, across this app's windows and command-line runs: two builds of the
/// same folder share <id>_build/ and the output app, and clobber each other.
struct FolderLock {
    let path: String

    init(_ dir: String) throws {
        path = dir + "/.nxnative-converter.lock"
        if let pid = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), let n = Int32(pid), kill(n, 0) == 0 {
            throw ConverterError("another build of this folder is running (process \(n)); wait for it to finish")
        }
        do { try String(getpid()).write(toFile: path, atomically: true, encoding: .utf8) } catch { throw ConverterError("cannot write \(path): \(error.localizedDescription)") }
    }

    func release() { try? FileManager.default.removeItem(atPath: path) }
}

/// The lines of a pipe as they arrive.
struct Lines: Sequence, IteratorProtocol {
    let handle: FileHandle
    var buffer = Data()
    var eof = false

    init(_ h: FileHandle) { handle = h }

    mutating func next() -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return String(decoding: line, as: UTF8.self)
            }
            if eof {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return String(decoding: buffer, as: UTF8.self)
            }
            let chunk = handle.availableData
            if chunk.isEmpty { eof = true } else { buffer.append(chunk) }
        }
    }
}
