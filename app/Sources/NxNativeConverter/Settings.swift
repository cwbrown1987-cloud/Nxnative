// Settings kept between runs in ~/Library/Application Support/NxNative Converter/settings.json.
// Paths only: the keys file's location is remembered, never its content.
import Foundation

enum Appearance: String, Codable, CaseIterable { case system = "System", light = "Light", dark = "Dark" }
enum LogDetail: String, Codable, CaseIterable { case standard = "Standard", detailed = "Detailed" }

struct Settings: Codable, Equatable {
    var repo: String?
    var python: String?
    var keys: String?
    var gameDir: String?
    /// codesign identity; nil = ad-hoc
    var signIdentity: String?
    /// where new apps go; nil = beside the game files
    var outDir: String?
    /// the keys file for a game folder that has no prod.keys of its own
    var defaultKeys: String?
    var appearance: Appearance = .system
    var notify = true
    var openAfterBuild = false
    /// false deletes the stage keys in <id>_build first, so every step runs again
    var reuseCache = true
    /// a rebuild moves the old app to app-backups/; false moves it to the Trash once the new one is built
    var keepBackups = true
    /// detailed: Copy log adds the tools' own logs from <id>_build/logs
    var logDetail: LogDetail = .standard

    enum CodingKeys: String, CodingKey {
        case repo, python, keys, appearance, notify
        case gameDir = "game_dir", signIdentity = "sign_identity", outDir = "out_dir", defaultKeys = "default_keys"
        case openAfterBuild = "open_after_build", reuseCache = "reuse_cache", keepBackups = "keep_backups", logDetail = "log_detail"
    }

    init() {}

    // every field optional on disk: older settings files (and the Rust app's) lack the newer ones
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        python = try c.decodeIfPresent(String.self, forKey: .python)
        keys = try c.decodeIfPresent(String.self, forKey: .keys)
        gameDir = try c.decodeIfPresent(String.self, forKey: .gameDir)
        signIdentity = try c.decodeIfPresent(String.self, forKey: .signIdentity)
        outDir = try c.decodeIfPresent(String.self, forKey: .outDir)
        defaultKeys = try c.decodeIfPresent(String.self, forKey: .defaultKeys)
        appearance = (try? c.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? .system
        notify = (try? c.decodeIfPresent(Bool.self, forKey: .notify)) ?? true
        openAfterBuild = (try? c.decodeIfPresent(Bool.self, forKey: .openAfterBuild)) ?? false
        reuseCache = (try? c.decodeIfPresent(Bool.self, forKey: .reuseCache)) ?? true
        keepBackups = (try? c.decodeIfPresent(Bool.self, forKey: .keepBackups)) ?? true
        logDetail = (try? c.decodeIfPresent(LogDetail.self, forKey: .logDetail)) ?? .standard
    }

    /// NXC_SUPPORT_DIR points the settings and build records elsewhere (for testing beside a running copy)
    static var supportDir: URL {
        if let d = ProcessInfo.processInfo.environment["NXC_SUPPORT_DIR"] { return URL(fileURLWithPath: d) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "NxNative Converter")
    }

    static func load() -> Settings {
        guard let d = try? Data(contentsOf: supportDir.appending(path: "settings.json")), let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
        return s
    }

    func save() {
        try? FileManager.default.createDirectory(at: Settings.supportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: Settings.supportDir.appending(path: "settings.json")) }
    }

    /// The preferences Restore defaults resets; the chosen folders and files stay.
    mutating func restoreDefaults() {
        let d = Settings()
        signIdentity = d.signIdentity; outDir = d.outDir; defaultKeys = d.defaultKeys; appearance = d.appearance; notify = d.notify
        openAfterBuild = d.openAfterBuild; reuseCache = d.reuseCache; keepBackups = d.keepBackups; logDetail = d.logDetail; python = nil
    }
}

extension String {
    /// "/Users/tom/Documents/x" → "~/Documents/x"
    var tildePath: String { (self as NSString).abbreviatingWithTildeInPath }
    var url: URL { URL(fileURLWithPath: self) }
    var lastComponent: String { (self as NSString).lastPathComponent }
}

/// "Today at 20:04", "Yesterday at 18:32", "Mar 10, 2025 at 14:17".
func relativeDay(_ d: Date) -> String {
    let cal = Calendar.current
    let time = d.formatted(date: .omitted, time: .shortened)
    if cal.isDateInToday(d) { return "Today at \(time)" }
    if cal.isDateInYesterday(d) { return "Yesterday at \(time)" }
    return "\(d.formatted(.dateTime.month(.abbreviated).day().year())) at \(time)"
}

/// Run a program and wait: (exit status 0, stdout or else stderr, trimmed). nil when it cannot start.
@discardableResult
func run(_ exe: String, _ args: [String], env: [String: String]? = nil, cwd: String? = nil) -> (ok: Bool, out: String)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { _, n in n } }
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: o.isEmpty ? e : o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return (p.terminationStatus == 0, text)
}

/// Single-quote a path for a shell command.
func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
