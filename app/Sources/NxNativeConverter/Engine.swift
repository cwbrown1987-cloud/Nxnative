// The engine is the nxnative checkout the script runs from: its commit is the version a game app is built
// with. Each successful build is recorded in builds.json (beside settings.json) with that commit, since the
// app bundle itself does not carry one; an app built before that shows as "unknown".
import Foundation

struct EngineVersion: Codable, Hashable {
    var commit: String
    var subject: String
    var date: String
    var branch: String
    /// uncommitted changes to tracked files in the checkout when it was read
    var dirty: Bool

    var short: String { String(commit.prefix(7)) }
    var label: String { "\(short)\(dirty ? "+changes" : "") · \(subject) · \(date)" }
}

struct BuildRecord: Codable, Hashable, Identifiable {
    var id: String { app }
    var app: String
    var gameDir: String
    var engine: EngineVersion
    var repo: String
    var builtAt: String
    /// stages completed, and the shader count the Mac shader stage reported (nil for builds recorded before)
    var steps: Int?
    var shaders: String?
    /// "Base game + update"
    var gameFiles: String?

    enum CodingKeys: String, CodingKey {
        case app, engine, repo, steps, shaders
        case gameDir = "game_dir"
        case builtAt = "built_at"
        case gameFiles = "game_files"
    }

    var date: Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: builtAt)
    }
}

/// An app moved aside by a rebuild: app-backups/<name> (<engine>, <yyyy-MM-dd-HH-mm>).app
struct Backup: Hashable, Identifiable {
    var id: String { path }
    let path: String
    let engine: String
    let date: Date?
}

enum Engine {
    private static func git(_ repo: String, _ args: [String]) -> String? {
        guard let r = run("/usr/bin/env", ["git", "-C", repo] + args, env: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]), r.ok else { return nil }
        return r.out
    }

    static func current(_ repo: String) -> EngineVersion? {
        guard let log = git(repo, ["log", "-1", "--format=%H%x1f%s%x1f%cs"]) else { return nil }
        let p = log.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 3 else { return nil }
        let branch = git(repo, ["rev-parse", "--abbrev-ref", "HEAD"]) ?? ""
        let dirty = !(git(repo, ["status", "--porcelain", "--untracked-files=no"]) ?? "").isEmpty
        return EngineVersion(commit: p[0], subject: p[1], date: p[2], branch: branch, dirty: dirty)
    }

    /// After a fetch: how many commits the upstream branch has that HEAD lacks.
    static func checkUpdates(_ repo: String) throws -> Int {
        guard git(repo, ["fetch", "--quiet", "origin"]) != nil else { throw ConverterError("git fetch failed") }
        guard let up = git(repo, ["rev-parse", "--abbrev-ref", "@{upstream}"]) else { throw ConverterError("this branch has no upstream branch to update from") }
        return Int(git(repo, ["rev-list", "--count", "HEAD..\(up)"]) ?? "0") ?? 0
    }

    /// Fast-forward to the upstream branch; refuses when that would need a merge.
    static func update(_ repo: String) throws {
        guard git(repo, ["pull", "--ff-only", "--quiet"]) != nil else { throw ConverterError("the engine cannot fast-forward (local changes or diverged branch)") }
    }

    private static var buildsFile: URL { Settings.supportDir.appending(path: "builds.json") }

    static func builds() -> [BuildRecord] {
        guard let d = try? Data(contentsOf: buildsFile) else { return [] }
        return (try? JSONDecoder().decode([BuildRecord].self, from: d)) ?? []
    }

    static func record(_ b: BuildRecord) {
        var all = builds().filter { $0.app != b.app }
        all.append(b)
        try? FileManager.default.createDirectory(at: Settings.supportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(all) { try? d.write(to: buildsFile) }
    }

    static func now() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }

    /// The game apps in a folder (top level), each with the build recorded for it.
    static func apps(in dir: String) -> [(app: String, build: BuildRecord?)] {
        let known = builds()
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return items.filter { $0.hasSuffix(".app") && FileManager.default.fileExists(atPath: "\(dir)/\($0)/Contents/MacOS/dmhost") }
            .sorted()
            .map { name in let p = "\(dir)/\(name)"; return (p, known.first { $0.app == p }) }
    }

    /// The copies a rebuild kept of this app, newest first.
    static func backups(of app: String) -> [Backup] {
        let u = app.url
        let dir = u.deletingLastPathComponent().appending(path: "app-backups").path
        let stem = u.deletingPathExtension().lastPathComponent + " ("
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH-mm"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(stem) && $0.hasSuffix(").app") }.map { name in
            let inner = name.dropFirst(stem.count).dropLast(5).split(separator: ", ")
            return Backup(path: "\(dir)/\(name)", engine: String(inner.first ?? "?"), date: inner.count > 1 ? f.date(from: String(inner[1])) : nil)
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// "Base game + update", "Base game + 2 DLC" from the folder's file names.
    static func describeFiles(_ dir: String) -> String {
        let names = GameFiles.list(in: dir.url).map(\.lastPathComponent)
        let tails = names.compactMap { n -> String? in
            guard let r = n.range(of: #"\[[0-9A-Fa-f]{16}\]"#, options: .regularExpression) else { return nil }
            return String(n[r].dropFirst(14).prefix(3))
        }
        let upd = tails.filter { $0 == "800" }.count
        let dlc = tails.filter { $0 != "800" && $0 != "000" }.count
        var parts = ["Base game"]
        if upd > 0 { parts.append("update") }
        if dlc > 0 { parts.append("\(dlc) DLC") }
        return parts.joined(separator: " + ")
    }

    /// Move an app aside before rebuilding it: <folder>/app-backups/<name> (<engine or "old engine">, <time>).app.
    /// A rename on the same volume, so it is instant and takes no space.
    static func backUp(_ app: String, engine: EngineVersion?) throws -> String {
        let u = URL(fileURLWithPath: app)
        let dir = u.deletingLastPathComponent().appending(path: "app-backups")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = now().replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "-")
        let dst = dir.appending(path: "\(u.deletingPathExtension().lastPathComponent) (\(engine?.short ?? "old engine"), \(stamp)).app")
        do { try FileManager.default.moveItem(at: u, to: dst) } catch { throw ConverterError("cannot move \(app) aside: \(error.localizedDescription)") }
        return dst.path
    }
}
