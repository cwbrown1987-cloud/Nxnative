// What the window shows about the game in a folder: its name and icon, from the last conversion's output
// (the extracted control data's icon.jpg, the app's CFBundleName) or else from the base NSP's file name.
import Foundation

struct GameInfo: Hashable {
    var name: String
    var icon: URL?

    static func read(_ dir: String) -> GameInfo {
        let fm = FileManager.default
        let build = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).first { $0.hasSuffix("_build") }.map { "\(dir)/\($0)" }
        // the newest extracted version's icon (nx_extract writes <version>/icon.jpg)
        let icon = build.flatMap { b -> URL? in
            let ex = b + "/extract"
            let icons = ((try? fm.contentsOfDirectory(atPath: ex)) ?? []).map { URL(fileURLWithPath: "\(ex)/\($0)/icon.jpg") }.filter { fm.fileExists(atPath: $0.path) }
            return icons.max { (mtime($0) ?? .distantPast) < (mtime($1) ?? .distantPast) }
        }
        let fromApp = Engine.apps(in: dir).first.flatMap { a -> String? in
            (NSDictionary(contentsOfFile: a.app + "/Contents/Info.plist")?["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let fromNSP = GameFiles.list(in: dir.url).lazy.compactMap { u -> String? in
            let n = u.deletingPathExtension().lastPathComponent
            guard n.contains("000]") || !n.contains("[") else { return nil }
            return String(n.components(separatedBy: " [")[0]).trimmingCharacters(in: .whitespaces)
        }.first
        return GameInfo(name: fromApp ?? fromNSP ?? dir.url.lastPathComponent, icon: icon)
    }

    private static func mtime(_ u: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
    }
}
