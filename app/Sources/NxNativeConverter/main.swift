// NxNative Converter: a window over scripts/build_ipa_from_nsp.py --platform mac-app.
// 1. lists what the script needs, ticked or crossed; 2. checks a game folder against prod.keys;
// 3. converts the folder to a signed Mac app, and rebuilds it when the engine changes. The same steps run headless:
//   NxNativeConverter --check | --validate <folder> <prod.keys> | --convert <folder> <prod.keys> [--sign <identity>]
//   | --rebuild <app> <prod.keys> [--sign <identity>] | --engine [<folder>] | --verify <app>
import AppKit
import SwiftUI

func mark(_ ok: Bool, optional: Bool = false) -> String { ok ? "✓" : optional ? "–" : "✗" }

@MainActor
enum CLI {
    static func check() -> Int32 {
        let (checks, _) = Toolchain.checkAll(Settings.load())
        for c in checks {
            print("\(mark(c.ok, optional: c.optional)) \(c.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(c.detail)\(c.optional ? "  (optional)" : "")")
            if !c.ok, let f = c.fix { print("      fix: \(f)") }
        }
        return checks.allSatisfy { $0.ok || $0.optional } ? 0 : 1
    }

    static func validate(_ dir: String, _ keys: String) -> Int32 {
        let v = GameFiles.validate(dir: dir.url, keysURL: keys.url)
        for l in v.summary { print("\(mark(l.ok)) \(l.text)") }
        for f in v.files {
            print("\(mark(f.ok)) \(f.name) (\(f.role))")
            for l in f.lines { print("    \(mark(l.ok)) \(l.text)") }
        }
        return v.ok ? 0 : 1
    }

    static func engine(_ dir: String?) -> Int32 {
        let (_, env) = Toolchain.checkAll(Settings.load())
        guard let repo = env.repo else { print("✗ no nxnative repository"); return 1 }
        guard let v = Engine.current(repo) else { print("✗ \(repo) is not a git checkout"); return 1 }
        print("engine \(repo) (\(v.branch)): \(v.label)")
        for (app, b) in dir.map(Engine.apps(in:)) ?? [] {
            if let b { print("\(mark(b.engine.commit == v.commit && !v.dirty)) \(app): \(b.engine.label)\(b.engine.commit == v.commit ? " (current)" : " (older engine)")") }
            else { print("✗ \(app): unknown engine (built before the converter tracked engines)") }
        }
        return 0
    }

    static func convert(_ dir: String, _ keys: String, sign: String?, rebuild: String?) -> Int32 {
        let (checks, env) = Toolchain.checkAll(Settings.load())
        let missing = checks.filter { !$0.ok && !$0.optional }.map(\.name)
        if !missing.isEmpty { print("✗ missing: \(missing.joined(separator: ", "))"); return 1 }
        if validate(dir, keys) != 0 { return 1 }
        let run = BuildRun()
        var shown = 0, last = ""
        run.onChange = {
            for s in run.done[shown...] { print("\(mark(s.ok)) \(s.line)") }
            shown = run.done.count
            let now = "[\(run.stage.k)/\(run.stage.n)] \(run.stage.name) · \(run.stage.step)"
            if run.running && now != last { print("  … \(now)"); last = now }
        }
        run.start(Job(gameDir: dir, keys: keys, sign: sign, env: env, rebuild: rebuild))
        while run.result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        switch run.result! {
        case .success(let m): print("✓ \(m)"); return 0
        case .failure(let e): print("✗ \(e)"); return 1
        }
    }
}

func signArg(_ a: [String]) -> String? { a.firstIndex(of: "--sign").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--check": exit(MainActor.assumeIsolated { CLI.check() })
case "--validate" where args.count >= 3: exit(MainActor.assumeIsolated { CLI.validate(args[1], args[2]) })
case "--engine": exit(MainActor.assumeIsolated { CLI.engine(args.count > 1 ? args[1] : nil) })
case "--convert" where args.count >= 3: exit(MainActor.assumeIsolated { CLI.convert(args[1], args[2], sign: signArg(args), rebuild: nil) })
case "--rebuild" where args.count >= 3:
    exit(MainActor.assumeIsolated { CLI.convert(args[1].url.deletingLastPathComponent().path, args[2], sign: signArg(args), rebuild: args[1]) })
case "--verify" where args.count >= 2:
    do { print("✓ \(try BuildRun.verify(args[1]))"); exit(0) } catch { print("✗ \(error)"); exit(1) }
case let a? where a.hasPrefix("--") && !a.hasPrefix("-NS") && !a.hasPrefix("-Apple"):
    FileHandle.standardError.write(Data("usage: NxNativeConverter [--check | --validate <folder> <prod.keys> | --convert <folder> <prod.keys> [--sign <identity>] | --rebuild <app> <prod.keys> [--sign <identity>] | --engine [<folder>] | --verify <app>]\n".utf8))
    exit(2)
default:
    ConverterApp.main()
}
