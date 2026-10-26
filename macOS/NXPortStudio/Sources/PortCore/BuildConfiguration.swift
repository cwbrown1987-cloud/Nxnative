import Foundation

public enum BuildDestination: String, Codable, CaseIterable, Sendable, Identifiable {
    case macOS, iOS
    public var id: String { rawValue }
}

public struct BuildConfiguration: Sendable {
    public var repositoryURL: URL
    public var gameDirectoryURL: URL
    public var keysURL: URL
    public var outputURL: URL
    public var destination: BuildDestination
    public var appName: String
    public var language: String
    public var showFPS: Bool
    public var prepareXcode: Bool
    public var teamID: String?

    public init(repositoryURL: URL, gameDirectoryURL: URL, keysURL: URL, outputURL: URL,
                destination: BuildDestination, appName: String = "", language: String = "",
                showFPS: Bool = false, prepareXcode: Bool = false, teamID: String? = nil) {
        self.repositoryURL = repositoryURL; self.gameDirectoryURL = gameDirectoryURL
        self.keysURL = keysURL; self.outputURL = outputURL; self.destination = destination
        self.appName = appName; self.language = language; self.showFPS = showFPS
        self.prepareXcode = prepareXcode; self.teamID = teamID
    }
}

public enum PortError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case processAlreadyRunning
    case launchFailed(String)
    case processFailed(Int32, String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let text), .launchFailed(let text): text
        case .processAlreadyRunning: "A process is already running."
        case .processFailed(let code, let output): "Process exited with status \(code).\n\(output)"
        }
    }
}

public struct ProcessCommand: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var workingDirectoryURL: URL?
    public var environment: [String: String]
    public var redactedDescription: String
    public init(executableURL: URL, arguments: [String] = [], workingDirectoryURL: URL? = nil,
                environment: [String: String] = [:], redactedDescription: String? = nil) {
        self.executableURL = executableURL; self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL; self.environment = environment
        self.redactedDescription = redactedDescription ?? executableURL.lastPathComponent
    }
}

public enum BuildCommand {
    public static func make(configuration c: BuildConfiguration, pythonURL: URL) throws -> ProcessCommand {
        let fm = FileManager.default
        let script = c.repositoryURL.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        guard fm.isReadableFile(atPath: script.path) else {
            throw PortError.invalidConfiguration("The nxnative build script was not found in the selected repository.")
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: c.gameDirectoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PortError.invalidConfiguration("Select a game folder containing its base game and optional updates or DLC.")
        }
        let files = try GameFolderSummary.inspect(c.gameDirectoryURL).files
        guard !files.isEmpty else {
            throw PortError.invalidConfiguration("The game folder contains no NSP, XCI, NSZ or XCZ files.")
        }
        guard fm.isReadableFile(atPath: c.keysURL.path),
              let keyMetadata = try? c.keysURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              keyMetadata.isRegularFile == true, (keyMetadata.fileSize ?? 0) > 0 else {
            throw PortError.invalidConfiguration("Select a readable, nonempty prod.keys file.")
        }
        guard c.destination == .iOS || !c.prepareXcode else {
            throw PortError.invalidConfiguration("Preparing an Xcode project requires the iOS destination.")
        }
        // Xcode preparation writes under the game's build folder, independently of the export path.
        if !c.prepareXcode {
            let expectedExtension = c.destination == .macOS ? "app" : "ipa"
            guard c.outputURL.pathExtension.lowercased() == expectedExtension else {
                throw PortError.invalidConfiguration("The output must end in .\(expectedExtension).")
            }
            // fileExists follows symlinks, including a dangling link whose target is not there yet.
            // Refuse that target explicitly; a selected parent symlink is resolved to its real volume.
            let outputIsSymlink = (try? fm.destinationOfSymbolicLink(atPath: c.outputURL.path)) != nil
            let outputParent = c.outputURL.deletingLastPathComponent().resolvingSymlinksInPath()
            guard !fm.fileExists(atPath: c.outputURL.path), !outputIsSymlink,
                  fm.isWritableFile(atPath: outputParent.path) else {
                throw PortError.invalidConfiguration("Choose a new output name in a writable folder; existing ports are never overwritten.")
            }
        }
        var args = ["-u", script.path, c.gameDirectoryURL.path, "-k", c.keysURL.path,
                    "--platform", c.destination == .macOS ? "mac-app" : "ios",
                    "--progress", "json", "--keep-extracted",
                    c.showFPS ? "--show-fps" : "--no-show-fps"]
        if !c.prepareXcode { args += ["-o", c.outputURL.path] }
        if !c.appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args += ["--app-name", c.appName] }
        if !c.language.isEmpty { args += ["--language", c.language] }
        if c.prepareXcode {
            args += ["--prepare-xcode", "--xcode-workspace", c.gameDirectoryURL.appendingPathComponent("NXPortStudio.xcworkspace").path]
            if let teamID = c.teamID, !teamID.isEmpty { args += ["--team-id", teamID] }
        }
        var env = ToolEnvironment.values
        env["PYTHONUNBUFFERED"] = "1"
        return ProcessCommand(executableURL: pythonURL, arguments: args, workingDirectoryURL: c.repositoryURL,
                              environment: env, redactedDescription: "nxnative: \(c.destination.rawValue), structured progress; keys path hidden")
    }
}

public enum ToolEnvironment {
    public static var values: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let candidates = ["/opt/homebrew/opt/dotnet@10/bin", "/opt/homebrew/opt/dotnet/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/opt/dotnet@10/bin", "/usr/local/opt/dotnet/bin", "/usr/local/bin", "/usr/local/share/dotnet", "/usr/local/share/dotnet/x64", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let inherited = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = (candidates + inherited).filter { seen.insert($0).inserted }.joined(separator: ":")
        for prefix in ["/opt/homebrew/opt/dotnet@10/libexec", "/opt/homebrew/opt/dotnet/libexec", "/usr/local/opt/dotnet@10/libexec", "/usr/local/opt/dotnet/libexec"] {
            if FileManager.default.isExecutableFile(atPath: prefix + "/dotnet") {
                env["DOTNET_ROOT"] = prefix
                break
            }
        }
        env["USER"] = env["USER"] ?? NSUserName()
        // This native build never serves HTTPS. Avoid .NET's unrelated first-run development
        // certificate creation, which can wait for Keychain interaction in a background GUI build.
        env["DOTNET_GENERATE_ASPNET_CERTIFICATE"] = "false"
        return env
    }
    public static func executable(named name: String) -> URL? {
        for path in (values["PATH"] ?? "").split(separator: ":") {
            let url = URL(fileURLWithPath: String(path)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
    public static var defaultPythonURL: URL {
        executable(named: "python3.14") ?? executable(named: "python3") ?? URL(fileURLWithPath: "/usr/bin/python3")
    }
}
