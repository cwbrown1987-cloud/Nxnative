// What scripts/build_ipa_from_nsp.py --platform mac-app needs, checked the way the script checks it
// (check_prereqs, its TOOL_PATHS before PATH), so a tick here means the script will find the same tool.
import Foundation

let scriptPath = "scripts/build_ipa_from_nsp.py"
let forkURL = "https://github.com/gnosticgeek/nxnative.git"

enum CheckGroup: String, CaseIterable { case system = "System", build = "Build tools", packaging = "Processing & packaging", optional = "Optional tools" }

struct Check: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let why: String
    let ok: Bool
    var optional = false
    /// the full finding: a path and version, or what is wrong
    let detail: String
    /// A shell command that installs or fixes it, run in Terminal on request.
    var fix: String?
    var group: CheckGroup = .system
    /// the table's "Version or location" cell
    var short = ""
    var symbol = "checkmark.seal"
}

/// Everything resolved while checking, which the conversion then uses.
struct ToolEnv: Hashable {
    var repo: String?
    var python: String?
    var path = ""
    /// the folder of the dotnet the script finds: the shader translator's launcher (an apphost) finds the
    /// runtime only through DOTNET_ROOT or /usr/local/share/dotnet, not through PATH
    var dotnetRoot: String?
}

enum Toolchain {
    static func isRepo(_ p: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: p + "/" + scriptPath) && fm.fileExists(atPath: p + "/dm/tools/nx_extract/Program.cs")
    }

    /// The repository: the setting, else the checkout this app sits in, else a few usual places.
    static func findRepo(_ s: Settings) -> String? {
        if let r = s.repo, isRepo(r) { return r }
        var cands: [String] = []
        var u = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        while u.path != "/" { u.deleteLastPathComponent(); cands.append(u.path) }
        let home = NSHomeDirectory()
        cands += ["Developer/nxnative", "nxnative", "src/nxnative", "Documents/nxnative", "Projects/nxnative", "code/nxnative"].map { home + "/" + $0 }
        cands.append(Settings.supportDir.appending(path: "nxnative").path)
        return cands.first(where: isRepo)
    }

    /// The script's TOOL_PATHS list, read from its source (it may be edited locally), else upstream's.
    static func toolPaths(_ repo: String?) -> [String] {
        let home = NSHomeDirectory()
        let fallback = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/share/dotnet", home + "/.dotnet"]
        guard let repo, let src = try? String(contentsOfFile: repo + "/" + scriptPath, encoding: .utf8),
              let line = src.split(separator: "\n").first(where: { $0.hasPrefix("TOOL_PATHS = [") }),
              let close = line.firstIndex(of: "]") else { return fallback }
        var out: [String] = []
        for part in line[line.index(line.startIndex, offsetBy: 14)..<close].split(separator: ",") {
            let q = part.split(separator: "'", omittingEmptySubsequences: false)
            if q.count >= 3 {
                let s = String(q[1])
                out.append(part.contains("expanduser") ? s.replacingOccurrences(of: "~", with: home, options: .anchored) : s)
            }
        }
        return out.isEmpty ? fallback : out
    }

    /// PATH as the script will see it: its TOOL_PATHS first, then ours (a Finder-launched app has a bare PATH).
    static func scriptPATH(_ repo: String?) -> String {
        var parts = toolPaths(repo)
        parts += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        parts += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    static func which(_ tool: String, _ path: String) -> String? {
        path.split(separator: ":").map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func firstLine(_ s: String) -> String { String(s.split(separator: "\n").first ?? "") }

    static func checkAll(_ s: Settings) -> ([Check], ToolEnv) {
        var v: [Check] = []
        let repo = findRepo(s)
        let path = scriptPATH(repo)
        let env = ["PATH": path]

        #if arch(arm64)
        v.append(Check(name: "Apple silicon Mac", why: "the game's own arm64 code runs natively", ok: true, detail: "arm64", short: "Apple silicon", symbol: "cpu"))
        #else
        v.append(Check(name: "Apple silicon Mac", why: "the game's own arm64 code runs natively", ok: false, detail: "this Mac has an Intel processor", short: "Intel", symbol: "cpu"))
        #endif

        let cloneTo = Settings.supportDir.appending(path: "nxnative").path
        v.append(Check(name: "nxnative repository", why: "the conversion script, rewriter, host and shader tools", ok: repo != nil,
                       detail: repo ?? "not found: choose its folder, or clone it", fix: "git clone \(forkURL) \(shq(cloneTo))",
                       short: repo?.tildePath ?? "Not found", symbol: "shippingbox"))

        let xb = which("xcodebuild", path).flatMap { run($0, ["-version"], env: env) }
        v.append(Check(name: "Xcode", why: "the Metal compiler, clang and the macOS SDK", ok: xb?.ok == true,
                       detail: xb.map { firstLine($0.out) } ?? "xcodebuild not found", fix: "open 'macappstore://apps.apple.com/app/id497799835'",
                       short: xb.map { firstLine($0.out) } ?? "Not found", symbol: "hammer"))
        let metal = run("/usr/bin/xcrun", ["-sdk", "macosx", "metal", "--version"], env: env)
        v.append(Check(name: "Metal toolchain", why: "compiles the Mac shader libraries", ok: metal?.ok == true,
                       detail: metal.map { firstLine($0.out) } ?? "xcrun not found", fix: "xcodebuild -downloadComponent MetalToolchain", group: .build,
                       short: metal.flatMap { m in m.ok ? m.out.split(separator: " ").dropFirst(3).first.map { "Apple Metal \($0)" } : nil } ?? "Not installed", symbol: "square.stack.3d.up"))
        for (tool, why, sym) in [("make", "builds the Mac host", "apple.terminal"), ("clang", "compiles the host and the app launcher", "hammer")] {
            let p = which(tool, path)
            v.append(Check(name: tool, why: why, ok: p != nil, detail: p ?? "not found", fix: "xcode-select --install", group: .build, short: p ?? "Not found", symbol: sym))
        }

        // dotnet: the first one on the script's PATH must have SDK 10 (nx_extract targets net10.0)
        let dn = which("dotnet", path)
        let dotnetRoot = dn.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().deletingLastPathComponent().path }
        let sdks = dn.flatMap { run($0, ["--list-sdks"], env: env)?.out } ?? ""
        let versions = sdks.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) }
        let has10 = versions.contains { $0.hasPrefix("10.") }
        let dnDetail: String
        if let dn { dnDetail = has10 ? "\(dn) (\(versions.joined(separator: ", ")))" : "\(dn) has SDK \(versions.isEmpty ? "none" : versions.joined(separator: ", ")) only; the script uses the first dotnet on its PATH" }
        else { dnDetail = "dotnet not found" }
        v.append(Check(name: ".NET SDK", why: "SDK 10 builds nx_extract, which reads the NSPs", ok: has10, detail: dnDetail,
                       fix: dotnetRoot.map { "curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0 --install-dir \(shq($0))" } ?? "brew install --cask dotnet-sdk",
                       group: .build, short: versions.last { $0.hasPrefix("10.") } ?? (versions.last.map { "\($0) (needs 10)" } ?? "Not found"), symbol: "chevron.left.forwardslash.chevron.right"))

        // the translator's launcher must start: it finds .NET only through DOTNET_ROOT (which the conversion sets)
        if let repo {
            let x = repo + "/dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate"
            var xenv = env
            if let dotnetRoot { xenv["DOTNET_ROOT"] = dotnetRoot }
            let r = run(x, ["--source-sha"], env: xenv)
            let sha = r.flatMap { $0.ok && !$0.out.isEmpty ? $0.out : nil }
            let detail = sha.map { "\(x) (source \($0))" } ?? (FileManager.default.fileExists(atPath: x) ? "does not start: it needs the .NET 10 runtime" : "\(x) is missing")
            v.append(Check(name: "Shader translator", why: "turns the game's Maxwell shaders into SPIR-V", ok: sha != nil, detail: detail, group: .build,
                           short: sha != nil ? "dmsh_xlate" : "Does not start", symbol: "cpu"))
        }

        for (tool, label, why, sym) in [("zstd", "zstd", "decompresses game data", "cylinder"), ("spirv-cross", "SPIRV-Cross", "SPIR-V to Metal Shading Language", "cube.transparent")] {
            let p = which(tool, path)
            v.append(Check(name: label, why: why, ok: p != nil, detail: p ?? "not found", fix: "brew install \(tool)", group: .packaging, short: p ?? "Not found", symbol: sym))
        }

        // Python: the setting, this app's venv, the checkout's .venv, then every python3 on PATH; the first with the modules wins
        var cands: [String] = []
        if let p = s.python { cands.append(p) }
        cands.append(Settings.supportDir.appending(path: "venv/bin/python3").path)
        if let repo { cands.append(repo + "/.venv/bin/python3") }
        cands += path.split(separator: ":").map { "\($0)/python3" }
        var seen = Set<String>()
        cands = cands.filter { FileManager.default.isExecutableFile(atPath: $0) && seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted }
        let probe = """
        import sys
        def has(m):
            try: __import__(m); return True
            except ImportError: return False
        miss=[m for m in ('lz4.block','capstone','fontTools') if not has(m)]
        if not (has('compression.zstd') or has('backports.zstd')): miss.append('backports.zstd')
        print('%d.%d.%d' % sys.version_info[:3]); print(','.join(miss))
        """
        var best: (py: String, miss: [String], ver: String)?
        for c in cands {
            guard let r = run(c, ["-I", "-c", probe], env: env), r.ok else { continue }
            let l = r.out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let miss = (l.count > 1 ? l[1] : "").split(separator: ",").map(String.init)
            if best == nil || miss.isEmpty { best = (c, miss, l.first ?? "") }
            if miss.isEmpty { break }
        }
        let venv = shq(Settings.supportDir.appending(path: "venv").path)
        let venvFix = "python3 -m venv \(venv) && \(venv)/bin/pip install lz4 capstone fonttools nsz \"backports.zstd; python_version < '3.14'\""
        var python: String?
        if let b = best, b.miss.isEmpty {
            python = b.py
            v.append(Check(name: "Python modules", why: "lz4, capstone, fontTools, zstd for the script", ok: true, detail: "\(b.py) (Python \(b.ver))", fix: venvFix,
                           group: .packaging, short: "Python \(b.ver.split(separator: ".").prefix(2).joined(separator: "."))", symbol: "curlybraces"))
        } else if let b = best {
            v.append(Check(name: "Python modules", why: "lz4, capstone, fontTools, zstd for the script", ok: false, detail: "\(b.py) (Python \(b.ver)) lacks \(b.miss.joined(separator: ", "))", fix: venvFix,
                           group: .packaging, short: "Missing \(b.miss.joined(separator: ", "))", symbol: "curlybraces"))
        } else {
            v.append(Check(name: "Python modules", why: "lz4, capstone, fontTools, zstd for the script", ok: false, detail: "no python3 found", fix: venvFix,
                           group: .packaging, short: "No python3", symbol: "curlybraces"))
        }

        let pack = ["codesign", "sips", "iconutil"].filter { which($0, path) == nil }
        v.append(Check(name: "App packaging", why: "codesign, sips, iconutil (part of macOS)", ok: pack.isEmpty,
                       detail: pack.isEmpty ? "codesign, sips, iconutil" : "missing: \(pack.joined(separator: ", "))", group: .packaging,
                       short: pack.isEmpty ? "codesign, sips, iconutil" : "Missing \(pack.joined(separator: ", "))", symbol: "shippingbox"))

        // optional: only some games or file types need them
        let gl = which("glslangValidator", path)
        v.append(Check(name: "glslang", why: "only OpenGL games (e.g. Fire Emblem: Three Houses)", ok: gl != nil, optional: true, detail: gl ?? "not found", fix: "brew install glslang",
                       group: .optional, short: "OpenGL shader support", symbol: "triangle"))
        let nsz = python.flatMap { run($0, ["-I", "-c", "import nsz"], env: env) }?.ok == true
        v.append(Check(name: "nsz", why: "only compressed .nsz / .xcz files", ok: nsz, optional: true, detail: nsz ? "installed" : "not installed in that Python",
                       fix: python.map { "\(shq($0)) -m pip install nsz" }, group: .optional, short: "Compressed game files", symbol: "doc.zipper"))

        return (v, ToolEnv(repo: repo, python: python, path: path, dotnetRoot: dotnetRoot))
    }

    /// Run a command in a new Terminal window, so the user sees it and can type a password.
    static func runInTerminal(_ cmd: String) {
        let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Terminal\"\nactivate\ndo script \"\(esc)\"\nend tell"]
        try? p.run()
    }

    /// Code signing identities from the keychain (names only), for the signing menu.
    static func signingIdentities() -> [String] {
        guard let r = run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]) else { return [] }
        return r.out.split(separator: "\n").compactMap { l in
            guard let a = l.firstIndex(of: "\""), let b = l.lastIndex(of: "\""), a < b else { return nil }
            return String(l[l.index(after: a)..<b])
        }
    }
}
