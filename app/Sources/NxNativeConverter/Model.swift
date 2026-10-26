// The window's state: settings, toolchain checks, the folder's validation, the engine and the build run.
// Slow work (checks, validation, git) runs off the main thread and lands back here.
import AppKit
import Observation
import UserNotifications

enum Page: String, CaseIterable, Identifiable {
    case convert = "Convert", builds = "Builds", toolchain = "Toolchain", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .convert: "macwindow.badge.plus"
        case .builds: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .toolchain: "wrench.and.screwdriver"
        case .settings: "gearshape"
        }
    }
}

enum BuildSort: String, CaseIterable { case newest = "Newest first", oldest = "Oldest first", name = "Name" }

@MainActor @Observable
final class AppModel {
    var page: Page = .convert
    var settings = Settings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if settings.appearance != oldValue.appearance { applyAppearance() }
        }
    }
    var checks: [Check]?
    var env: ToolEnv?
    var checking = false
    var lastChecked: Date?
    var validation: Validation?
    var validating = false
    var validatedFor: (String, String)?
    var game: GameInfo?
    var engine: EngineVersion?
    var engineMessage: (ok: Bool, text: String)?
    var engineBusy = false
    var identities: [String] = []
    let run = BuildRun()
    /// bumped when a build ends or files move, so lists of apps on disk are read again
    var revision = 0
    var buildSearch = ""
    var buildSort: BuildSort = .newest
    var selectedBuild: String?

    init() {
        run.onChange = { [weak self] in
            guard let self, !self.run.running, let r = self.run.result else { return }
            self.refreshGame()
            self.revision += 1
            self.buildEnded(r)
        }
        applyAppearance()
        recheck()
        if settings.gameDir != nil && settings.keys != nil { validate() }
    }

    var allOK: Bool { checks?.allSatisfy { $0.ok || $0.optional } ?? false }
    var passed: Int { checks?.filter(\.ok).count ?? 0 }
    var valid: Bool {
        guard let v = validation, let f = validatedFor else { return false }
        return v.ok && f.0 == settings.gameDir && f.1 == settings.keys
    }
    var ready: Bool { allOK && valid && !run.running }

    func applyAppearance() {
        switch settings.appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func recheck() {
        checking = true
        let s = settings
        Task.detached {
            let (c, e) = Toolchain.checkAll(s)
            let ids = Toolchain.signingIdentities()
            let ver = e.repo.flatMap(Engine.current)
            await MainActor.run {
                self.checks = c; self.env = e; self.identities = ids; self.engine = ver; self.checking = false; self.lastChecked = Date()
            }
        }
    }

    func validate() {
        guard let dir = settings.gameDir, let keys = settings.keys else { return }
        validating = true
        validation = nil
        validatedFor = (dir, keys)
        refreshGame()
        Task.detached {
            let v = GameFiles.validate(dir: dir.url, keysURL: keys.url)
            await MainActor.run { self.validation = v; self.validating = false }
        }
    }

    func refreshGame() {
        game = settings.gameDir.map(GameInfo.read)
    }

    func setGameDir(_ dir: String) {
        // prod.keys beside the game files is the usual layout; else the default keys file, else the one chosen before
        let beside = dir + "/prod.keys"
        if FileManager.default.fileExists(atPath: beside) { settings.keys = beside }
        else if let d = settings.defaultKeys, FileManager.default.fileExists(atPath: d) { settings.keys = d }
        settings.gameDir = dir
        validate()
    }

    func engineAction(update: Bool) {
        guard let repo = env?.repo else { return }
        engineBusy = true
        engineMessage = (true, update ? "Updating…" : "Checking…")
        Task.detached {
            let msg: (Bool, String)
            do {
                if update { try Engine.update(repo); msg = (true, "Updated") }
                else { let n = try Engine.checkUpdates(repo); msg = (true, n == 0 ? "Up to date" : "\(n) update\(n == 1 ? "" : "s") available") }
            } catch { msg = (false, "\(error)") }
            let ver = Engine.current(repo)
            await MainActor.run { self.engineMessage = msg; self.engine = ver; self.engineBusy = false }
        }
    }

    var updatesAvailable: Bool { engineMessage.map { $0.ok && $0.text.contains("available") } ?? false }

    /// The folder new apps go to: the setting, else beside the game files.
    var outputFolder: String? { settings.outDir ?? settings.gameDir }

    func build(rebuild: String? = nil) {
        guard let env, let dir = settings.gameDir, let keys = settings.keys else { return }
        let name = game?.name ?? ""
        let out = settings.outDir.flatMap { $0 == dir || name.isEmpty ? nil : "\($0)/\(name.replacingOccurrences(of: ":", with: " - ").replacingOccurrences(of: "/", with: " - ")).app" }
        run.start(Job(gameDir: dir, keys: keys, sign: settings.signIdentity, env: env, rebuild: rebuild, out: out,
                      keepBackup: settings.keepBackups, reuseCache: settings.reuseCache))
    }

    /// Rebuild a recorded app: its own game folder becomes the chosen one first.
    func rebuild(_ b: BuildRecord) {
        if settings.gameDir != b.gameDir { setGameDir(b.gameDir) }
        page = .convert
        Task {
            while validating { try? await Task.sleep(for: .milliseconds(200)) }
            if ready { build(rebuild: b.app) }
        }
    }

    private func buildEnded(_ r: Result<String, ConverterError>) {
        let name = game?.name ?? "The game"
        if settings.notify, Bundle.main.bundleIdentifier != nil {
            let c = UNMutableNotificationContent()
            switch r {
            case .success: c.title = "\(name) is ready"; c.body = "The Mac app was built and signed."
            case .failure(let e): c.title = "Build failed"; c.body = e.description
            }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
        if settings.openAfterBuild, case .success = r, let app = run.app { NSWorkspace.shared.open(app.url) }
    }

    func requestNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// The game's build cache, <game folder>/<title ID>_build.
    var buildCache: String? {
        guard let dir = settings.gameDir else { return nil }
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).first { $0.hasSuffix("_build") }.map { "\(dir)/\($0)" }
    }

    /// Everything the converter knows, for a bug report (no key values: the keys file is named, never read here).
    var diagnostics: String {
        var l = ["NxNative Converter diagnostics, \(Date().formatted())",
                 "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                 "engine: \(env?.repo ?? "none") \(engine?.label ?? "")",
                 "python: \(env?.python ?? "none")", "DOTNET_ROOT: \(env?.dotnetRoot ?? "none")", "PATH: \(env?.path ?? "")", ""]
        l += (checks ?? []).map { "\($0.ok ? "✓" : $0.optional ? "–" : "✗") \($0.name): \($0.detail)" }
        return l.joined(separator: "\n")
    }

    /// Copy log's text: the stages, the script's messages and, with detailed logs, the tools' own logs.
    var logText: String {
        var t = (run.done.map(\.line) + run.log).joined(separator: "\n")
        if settings.logDetail == .detailed, let cache = buildCache {
            let logs = cache + "/logs"
            for f in ((try? FileManager.default.contentsOfDirectory(atPath: logs)) ?? []).sorted() {
                if let s = try? String(contentsOfFile: "\(logs)/\(f)", encoding: .utf8) { t += "\n\n==== \(f) ====\n" + s }
            }
        }
        return t
    }

    func choose(folder: Bool, start: String? = nil) -> String? {
        let p = NSOpenPanel()
        p.canChooseDirectories = folder
        p.canChooseFiles = !folder
        p.allowsMultipleSelection = false
        if let start { p.directoryURL = start.url }
        return p.runModal() == .OK ? p.url?.path : nil
    }

    func confirm(_ title: String, _ text: String, action: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: action)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}
