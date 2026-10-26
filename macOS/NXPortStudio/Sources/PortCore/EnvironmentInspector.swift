import Foundation

public struct DependencyStatus: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isAvailable: Bool
    public let detail: String
    public let remediation: String?
    public let isRequired: Bool
    public init(id: String, name: String, isAvailable: Bool, detail: String,
                remediation: String? = nil, isRequired: Bool = true) {
        self.id = id; self.name = name; self.isAvailable = isAvailable
        self.detail = detail; self.remediation = remediation; self.isRequired = isRequired
    }
}

public enum EnvironmentInspector {
    public static func inspect(repositoryURL: URL, pythonURL: URL,
                               destination: BuildDestination = .iOS) async -> [DependencyStatus] {
        await withTaskGroup(of: DependencyStatus.self) { group in
            group.addTask {
                #if arch(arm64)
                let available = true
                let detail = "ARM64 Mac"
                #else
                let available = false
                let detail = "An M1 or newer Mac is required."
                #endif
                return DependencyStatus(id: "silicon", name: "Apple silicon", isAvailable: available,
                                        detail: detail)
            }
            group.addTask {
                let script = repositoryURL.appendingPathComponent("scripts/build_ipa_from_nsp.py")
                let translator = repositoryURL.appendingPathComponent("dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate")
                let available = FileManager.default.isReadableFile(atPath: script.path) && FileManager.default.fileExists(atPath: translator.path)
                return DependencyStatus(id: "engine", name: "nxnative engine", isAvailable: available,
                                        detail: available ? "Build script and shader translator found" : "Build script or bundled shader translator missing.",
                                        remediation: "Select a complete nxnative checkout.")
            }
            group.addTask { await check(id: "xcode", name: "Xcode", executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"), args: ["-version"], remediation: "Install Xcode from the App Store and open it once.") }
            group.addTask { await check(id: "metal", name: "Metal compiler", executable: URL(fileURLWithPath: "/usr/bin/xcrun"), args: ["-sdk", destination == .macOS ? "macosx" : "iphoneos", "metal", "--version"], remediation: "Install the Metal Toolchain in Xcode Settings > Components, or run xcodebuild -downloadComponent MetalToolchain.") }
            group.addTask {
                await check(id: "python", name: "Python packages", executable: pythonURL,
                            args: ["-c", "import lz4.block, capstone, fontTools; import sys; __import__('compression.zstd' if sys.version_info >= (3,14) else 'backports.zstd'); print('Python dependencies ready')"],
                            remediation: "Use Prepare environment to install packages into the app's isolated Python environment.")
            }
            group.addTask {
                guard let url = ToolEnvironment.executable(named: "dotnet") else {
                    return DependencyStatus(id: "dotnet", name: ".NET 10 SDK and runtime", isAvailable: false, detail: "dotnet was not found.", remediation: "Install .NET 10 SDK from Microsoft, or brew install --formula dotnet@10.")
                }
                let sdk = try? await ProcessRunner().run(ProcessCommand(executableURL: url, arguments: ["--list-sdks"]))
                let runtime = try? await ProcessRunner().run(ProcessCommand(executableURL: url, arguments: ["--list-runtimes"]))
                let sdkFound = sdk?.output.split(separator: "\n").contains(where: { (Int($0.split(separator: ".").first ?? "") ?? 0) >= 10 }) == true
                let runtimeFound = runtime?.output.contains("Microsoft.NETCore.App 10.") == true
                return DependencyStatus(id: "dotnet", name: ".NET 10 SDK and runtime", isAvailable: sdkFound && runtimeFound,
                                        detail: sdkFound && runtimeFound ? "Compatible SDK and .NET 10 runtime installed" : "Both an SDK >=10 and Microsoft.NETCore.App 10.x are required.",
                                        remediation: "Install Microsoft's .NET 10 SDK (including its .NET 10 runtime).")
            }
            for (id, name, arguments, required) in [("xcodegen", "XcodeGen", ["--version"], destination == .iOS),
                                                     ("zstd", "Zstandard", ["--version"], true),
                                                     ("spirv-cross", "SPIRV-Cross", ["--revision"], true),
                                                     ("glslangValidator", "glslang", ["--version"], false),
                                                     ("make", "Make", ["--version"], true)] {
                group.addTask {
                    guard let url = ToolEnvironment.executable(named: id) else {
                        return DependencyStatus(id: id, name: name, isAvailable: false, detail: "Not found in the tool search path.",
                                                remediation: id == "make" ? "Install Xcode." : "Install the relevant Homebrew package.", isRequired: required)
                    }
                    return await check(id: id, name: name, executable: url, args: arguments,
                                       remediation: "Repair the \(name) installation.", required: required)
                }
            }
            var statuses: [DependencyStatus] = []
            for await status in group { statuses.append(status) }
            let order = ["silicon", "engine", "xcode", "metal", "python", "dotnet", "xcodegen", "zstd", "spirv-cross", "glslangValidator", "make"]
            return statuses.sorted { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
        }
    }

    private static func check(id: String, name: String, executable: URL, args: [String],
                              remediation: String, required: Bool = true) async -> DependencyStatus {
        do {
            let result = try await ProcessRunner().run(ProcessCommand(executableURL: executable, arguments: args))
            return DependencyStatus(id: id, name: name, isAvailable: result.exitCode == 0,
                                    detail: result.output.split(separator: "\n").first.map(String.init) ?? "No version output",
                                    remediation: result.exitCode == 0 ? nil : remediation, isRequired: required)
        } catch {
            return DependencyStatus(id: id, name: name, isAvailable: false, detail: error.localizedDescription,
                                    remediation: remediation, isRequired: required)
        }
    }
}

public enum EnvironmentSetup {
    /// This only returns a plan. The GUI executes it after the user chooses Prepare environment.
    /// Homebrew's versioned .NET formula avoids an interactive administrator installer.
    public static func commands(pythonURL: URL, venvURL: URL, dependencies: [DependencyStatus] = []) -> [ProcessCommand] {
        var commands: [ProcessCommand] = []
        if let brew = ToolEnvironment.executable(named: "brew") {
            let packages = [("xcodegen", "xcodegen"), ("zstd", "zstd"), ("spirv-cross", "spirv-cross"), ("glslangValidator", "glslang")]
                .filter { ToolEnvironment.executable(named: $0.0) == nil }.map(\.1)
            if !packages.isEmpty {
                commands.append(ProcessCommand(executableURL: brew, arguments: ["install"] + packages,
                                               redactedDescription: "Install nxnative tools with Homebrew"))
            }
            if ToolEnvironment.executable(named: "dotnet") == nil || dependencies.first(where: { $0.id == "dotnet" })?.isAvailable == false {
                commands.append(ProcessCommand(executableURL: brew, arguments: ["install", "--formula", "dotnet@10"],
                                               redactedDescription: "Install the .NET 10 SDK and runtime with Homebrew"))
            }
        }
        commands.append(ProcessCommand(executableURL: pythonURL, arguments: ["-m", "venv", venvURL.path],
                                       redactedDescription: "Create isolated Python environment"))
        commands.append(ProcessCommand(executableURL: venvURL.appendingPathComponent("bin/python3"),
                                       arguments: ["-m", "pip", "install", "--no-binary=lz4", "lz4", "capstone", "fonttools", "backports.zstd; python_version < '3.14'", "nsz"],
                                       environment: ["PYLZ4_USE_SYSTEM_LZ4": "0"], redactedDescription: "Install Python build dependencies"))
        return commands
    }
}

public struct GameFolderSummary: Sendable {
    public let files: [URL]
    public let byteCount: Int64
    public var estimatedFreeBytesNeeded: Int64 { byteCount * 2 + 10 * 1_073_741_824 }
    public static func inspect(_ folderURL: URL) throws -> Self {
        let files = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
            .filter { ["nsp", "xci", "nsz", "xcz"].contains($0.pathExtension.lowercased()) &&
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        var bytes: Int64 = 0
        for file in files {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        return Self(files: files.sorted { $0.lastPathComponent < $1.lastPathComponent }, byteCount: bytes)
    }
}
