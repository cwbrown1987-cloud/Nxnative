import AppKit
import Observation
import PortCore
import UniformTypeIdentifiers

enum StudioPage: String, CaseIterable, Identifiable {
    case create = "New port", devices = "Devices", environment = "Environment", log = "Activity"
    var id: Self { self }
    var icon: String {
        switch self { case .create: "shippingbox"; case .devices: "ipad.and.iphone"; case .environment: "slider.horizontal.3"; case .log: "terminal" }
    }
}

@MainActor @Observable
final class StudioModel {
    var page: StudioPage = .create
    var gamePath = ""
    var keysPath = UserDefaults.standard.string(forKey: "keysPath") ?? ""
    var outputFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path
    var repositoryPath = ""
    var appName = ""
    var destination: BuildDestination = .macOS
    var language = "es"
    var showFPS = false
    var installMode = false
    var teamID = UserDefaults.standard.string(forKey: "teamID") ?? ""
    var devices: [AppleDevice] = []
    var selectedDeviceID = ""
    var dependencies: [DependencyStatus] = []
    var isChecking = false
    var isDiscoveringDevices = false
    var isBusy = false
    var isPreparing = true
    var status = "Preparing engine"
    var failure: String?
    var logs: [String] = []
    var stageName = ""
    var stepName = ""
    var stageIndex = 0
    var stageTotal = 0
    var progress: Double?
    var completedURL: URL?
    var projectURL: URL?
    var pastedKeys = ""
    var showingKeysSheet = false
    var gameFiles: [URL] = []
    var inputBytes: Int64 = 0
    @ObservationIgnored let runner = ProcessRunner()
    @ObservationIgnored var currentTask: Task<Void, Never>?
    @ObservationIgnored var operationID = UUID()

    var supportURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("NX Port Studio") }
    var pythonURL: URL {
        let venv = supportURL.appendingPathComponent("venv/bin/python3")
        return FileManager.default.isExecutableFile(atPath: venv.path) ? venv : ToolEnvironment.defaultPythonURL
    }
    var outputName: String {
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = (name.isEmpty ? URL(fileURLWithPath: gamePath).lastPathComponent : name)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
        return (safe.isEmpty ? "My Port" : safe) + (destination == .macOS ? ".app" : ".ipa")
    }
    var outputURL: URL { URL(fileURLWithPath: outputFolder).appendingPathComponent(outputName) }
    var selectedDevice: AppleDevice? { devices.first { $0.id == selectedDeviceID } }
    var missingRequirements: [DependencyStatus] { dependencies.filter { $0.isRequired && !$0.isAvailable } }
    var canBuild: Bool { !isBusy && !isPreparing && !isChecking && missingRequirements.isEmpty && !gameFiles.isEmpty && !keysPath.isEmpty && !repositoryPath.isEmpty }
    var approximateSpace: String { ByteCountFormatter.string(fromByteCount: inputBytes * 2 + 10_000_000_000, countStyle: .file) }

    func initialize() async {
        guard repositoryPath.isEmpty else { return }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: supportURL, withIntermediateDirectories: true)
            if let custom = UserDefaults.standard.string(forKey: "repositoryPath"), fm.isReadableFile(atPath: custom + "/scripts/build_ipa_from_nsp.py") {
                repositoryPath = custom
            } else if let engine = Bundle.main.resourceURL?.appendingPathComponent("nxnative"), fm.fileExists(atPath: engine.path) {
                let version = (try? String(contentsOf: engine.appendingPathComponent("ENGINE_REVISION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "bundled-1"
                let target = supportURL.appendingPathComponent("Engine/" + version)
                if !fm.fileExists(atPath: target.path) {
                    status = "Copying engine"
                    try await Task.detached {
                        let files = FileManager.default
                        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let staging = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                        try files.copyItem(at: engine, to: staging)
                        try files.moveItem(at: staging, to: target)
                    }.value
                }
                repositoryPath = target.path
            } else {
                let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                guard fm.isReadableFile(atPath: source.appendingPathComponent("scripts/build_ipa_from_nsp.py").path) else { throw PortError.invalidConfiguration(t("Select the nxnative source folder in Environment.")) }
                repositoryPath = source.path
            }
            status = "Ready to configure"
        } catch { failure = error.localizedDescription; status = "Engine unavailable" }
        isPreparing = false
        await checkEnvironment()
    }

    func chooseGame() {
        let panel = NSOpenPanel()
        panel.title = t("Choose one game's folder")
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setGame(url)
    }
    func setGame(_ url: URL) {
        var directory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        let folder = directory.boolValue ? url : url.deletingLastPathComponent()
        gamePath = folder.path
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
        gameFiles = files.filter { ["nsp", "xci", "nsz", "xcz"].contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        inputBytes = gameFiles.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        if appName.isEmpty { appName = folder.lastPathComponent }
        failure = gameFiles.isEmpty ? t("This folder has no NSP, XCI, NSZ or XCZ files.") : nil
        completedURL = nil; projectURL = nil
    }
    func chooseKeys() {
        let panel = NSOpenPanel(); panel.title = t("Choose prod.keys")
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        keysPath = url.path; UserDefaults.standard.set(keysPath, forKey: "keysPath")
    }
    func savePastedKeys() {
        do {
            let text = pastedKeys.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.contains("=") else { throw PortError.invalidConfiguration(t("Paste the contents of your prod.keys file.")) }
            let folder = supportURL.appendingPathComponent("Secrets")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent("prod.keys")
            try Data((text + "\n").utf8).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            keysPath = file.path; UserDefaults.standard.set(keysPath, forKey: "keysPath")
            pastedKeys = ""; showingKeysSheet = false; failure = nil
        } catch { failure = error.localizedDescription }
    }
    func chooseOutput() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: outputFolder)
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url.path }
    }
    func chooseRepository() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            repositoryPath = url.path; UserDefaults.standard.set(url.path, forKey: "repositoryPath")
            Task { await checkEnvironment() }
        }
    }
    func checkEnvironment() async {
        guard !isChecking, !repositoryPath.isEmpty else { return }
        isChecking = true
        let path = repositoryPath, target = destination
        let result = await EnvironmentInspector.inspect(repositoryURL: URL(fileURLWithPath: path), pythonURL: pythonURL, destination: target)
        if repositoryPath == path && destination == target { dependencies = result }
        isChecking = false
        if repositoryPath != path || destination != target { await checkEnvironment() }
    }
    func appendLog(_ line: String) {
        var safe = line
        if !keysPath.isEmpty { safe = safe.replacingOccurrences(of: keysPath, with: "<prod.keys>") }
        safe = LogRedactor.clean(safe)
        logs.append(safe)
        if logs.count > 1800 { logs.removeFirst(logs.count - 1800) }
    }
    func receive(_ line: String) {
        guard let event = ProgressEvent.decode(line: line) else { appendLog(line); return }
        if let name = event.stageName { stageName = name }
        if let step = event.stepName { stepName = step }
        if let k = event.k { stageIndex = k }
        if let n = event.n { stageTotal = n }
        if event.ev == "stage" { progress = nil; stepName = "" }
        if let value = event.fraction { progress = value }
        if let message = event.message {
            appendLog(message)
            if message.hasPrefix("game project: ") { projectURL = URL(fileURLWithPath: String(message.dropFirst("game project: ".count))) }
        }
        if event.ev == "stage_end" { appendLog("\(event.ok == false ? "Failed" : "Completed"): \(stageName) \(event.summary ?? "")") }
    }
    func build() {
        guard canBuild else { return }
        failure = nil; completedURL = nil; projectURL = nil
        progress = nil; stageIndex = 0; stageTotal = 0; stageName = ""; logs = []
        isBusy = true; status = "Building port"
        let config = BuildConfiguration(repositoryURL: URL(fileURLWithPath: repositoryPath), gameDirectoryURL: URL(fileURLWithPath: gamePath), keysURL: URL(fileURLWithPath: keysPath), outputURL: outputURL, destination: destination, appName: appName, language: language, showFPS: showFPS, prepareXcode: destination == .iOS && installMode, teamID: teamID.isEmpty ? nil : teamID)
        let runID = UUID(); operationID = runID
        currentTask = Task { [self] in
            do {
                let command = try BuildCommand.make(configuration: config, pythonURL: pythonURL)
                appendLog(command.redactedDescription)
                let result = try await runner.run(command) { [weak self] line in Task { @MainActor in
                    guard let self, self.operationID == runID else { return }
                    self.receive(line)
                } }
                try Task.checkCancellation()
                guard result.exitCode == 0 else { throw PortError.processFailed(result.exitCode, t("Build failed. Review Activity and the game's build/logs folder.")) }
                if config.prepareXcode {
                    if projectURL == nil {
                        for line in result.output.split(separator: "\n") {
                            if let event = ProgressEvent.decode(line: String(line)), let message = event.message, message.hasPrefix("game project: ") {
                                projectURL = URL(fileURLWithPath: String(message.dropFirst("game project: ".count)))
                            }
                        }
                    }
                    if projectURL == nil { projectURL = try locateProject(in: config.gameDirectoryURL) }
                    guard let projectURL, FileManager.default.fileExists(atPath: projectURL.path) else { throw PortError.invalidConfiguration(t("The build finished without a prepared Xcode project.")) }
                    completedURL = projectURL; status = "Ready to install"
                } else {
                    guard FileManager.default.fileExists(atPath: config.outputURL.path) else { throw PortError.invalidConfiguration(t("The build finished without the expected output.")) }
                    completedURL = config.outputURL; status = "Port created"
                    NSWorkspace.shared.activateFileViewerSelecting([config.outputURL])
                }
                progress = 1
            } catch is CancellationError { status = "Cancelled"; appendLog("Build cancelled.") }
            catch { failure = error.localizedDescription; status = "Build failed"; appendLog(error.localizedDescription) }
            operationID = UUID(); isBusy = false; currentTask = nil
        }
    }
    func locateProject(in folder: URL) throws -> URL? {
        let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let projects = children.filter { $0.lastPathComponent.hasSuffix("_build") }.map { $0.appendingPathComponent("xcode/DmIOS.xcodeproj") }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard projects.count == 1 else { return nil }
        return projects.first
    }
    func cancel() { currentTask?.cancel(); runner.cancel() }
    func revealOutput() { if let completedURL { NSWorkspace.shared.activateFileViewerSelecting([completedURL]) } }
    func openURL(_ string: String) { if let url = URL(string: string) { NSWorkspace.shared.open(url) } }
    func exportLog() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "NX-Port-Studio.log"
        if panel.runModal() == .OK, let url = panel.url { try? logs.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
    }
}
