// Convert: the game folder and keys, the Mac app's output, and the build's seven stages.
import AppKit
import SwiftUI

/// The script's stage names, as the window shows them.
let stageNames: [(String, String)] = [
    ("build nx_extract", "Extract tools"), ("extract", "Extract game files"), ("rewrite", "Rewrite executable"),
    ("shader split", "Split shaders"), ("Mac shaders", "Compile Metal shaders"), ("Mac host", "Build Mac host"), ("Mac app", "Package Mac app"),
]

func friendly(_ name: String) -> String {
    stageNames.first { name.hasPrefix($0.0) }?.1 ?? name.prefix(1).uppercased() + name.dropFirst()
}

func mmss(_ s: Int) -> String { "\(s / 60):\(String(format: "%02d", s % 60))" }

struct ConvertPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Convert game", subtitle: "Create a native Mac app from your game files.")
            HStack(alignment: .top, spacing: 16) {
                SourceFilesCard(model: model)
                MacAppCard(model: model)
            }
            .fixedSize(horizontal: false, vertical: true)
            ActivityCard(model: model)
        }
    }
}

struct SourceFilesCard: View {
    @Bindable var model: AppModel

    var body: some View {
        Card(title: "Source files", subtitle: "Select your game directory and prod.keys file.") {
            PathField(label: "Game folder", labelWidth: 100, symbol: "folder", value: model.settings.gameDir?.tildePath) {
                if let d = model.choose(folder: true, start: model.settings.gameDir) { model.setGameDir(d) }
            }
            .disabled(model.run.running)
            PathField(label: "Keys file", labelWidth: 100, symbol: "doc", value: model.settings.keys?.tildePath) {
                if let f = model.choose(folder: false, start: model.settings.gameDir) { model.settings.keys = f; model.validate() }
            }
            .disabled(model.run.running)

            if model.validating {
                HStack { ProgressView().controlSize(.small); Text("Checking the game files against your keys…").foregroundStyle(.secondary) }
            } else if let v = model.validation {
                HStack {
                    StatusDot(color: v.ok ? .green : .red)
                    Text(v.ok ? "Keys validated · \(v.keysSummary)" : "Validation failed\(v.keysSummary.isEmpty ? "" : " · \(v.keysSummary)")").foregroundStyle(.secondary)
                }
                ForEach(v.summary.filter { !$0.ok }, id: \.self) { Text($0.text).font(.callout).foregroundStyle(.red) }
            } else if model.settings.gameDir != nil && model.settings.keys != nil {
                Button("Validate") { model.validate() }.buttonStyle(.glass)
            }

            if let v = model.validation, !v.files.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.game?.name ?? "Game").font(.title3.weight(.semibold))
                    Text("\(v.files.count) game file\(v.files.count == 1 ? "" : "s") detected.").foregroundStyle(.secondary)
                }
                InsetTable {
                    tableRow("File", "Type", nil).font(.caption).foregroundStyle(.secondary).background(.quaternary.opacity(0.4))
                    ForEach(v.files) { f in
                        Divider()
                        tableRow(fileLabel(f), f.role, f).help(([f.name] + f.lines.map { "\($0.ok ? "✓" : "✗") \($0.text)" }).joined(separator: "\n"))
                        ForEach(f.lines.filter { !$0.ok }, id: \.self) { l in
                            Text(l.text).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 6)
                        }
                    }
                }
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Engine").font(.headline)
                    Text("NxNative engine version").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                EngineStatus(model: model)
                if model.updatesAvailable {
                    Button("Update engine") { model.engineAction(update: true) }.buttonStyle(.glassProminent)
                        .disabled(model.run.running || model.engine?.dirty == true || model.engineBusy)
                } else {
                    Button("Check for updates…") { model.engineAction(update: false) }.buttonStyle(.glass).disabled(model.run.running || model.engineBusy || model.engine == nil)
                }
            }
        }
    }

    func tableRow(_ file: String, _ type: String, _ f: FileReport?) -> some View {
        HStack(spacing: 10) {
            if f != nil { Image(systemName: "doc").foregroundStyle(.secondary).frame(width: 16) } else { Color.clear.frame(width: 16, height: 1) }
            Text(file).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Text(type).lineLimit(1).frame(width: 130, alignment: .leading)
            Group {
                if let f { StatusDot(color: f.ok ? .green : .red, text: f.ok ? "Ready" : "Failed") } else { Text("Status") }
            }
            .frame(width: 80, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, f == nil ? 6 : 9)
    }

    /// "Base game.nsp", "Update.nsp", "DLC.nsp": the full name is in the row's tooltip.
    func fileLabel(_ f: FileReport) -> String {
        let ext = (f.name as NSString).pathExtension
        let word = f.role.hasPrefix("Update") ? "Update" : f.role.hasPrefix("Base") ? "Base game" : f.role.hasPrefix("DLC") ? "DLC" : (f.name as NSString).deletingPathExtension
        return "\(word).\(ext)"
    }
}

/// "● 49a670a · Current" in green, blue when updates wait, red when the check failed.
struct EngineStatus: View {
    let model: AppModel

    var body: some View {
        if let e = model.engine {
            let failed = model.engineMessage?.ok == false
            HStack(spacing: 7) {
                if model.engineBusy { ProgressView().controlSize(.mini) }
                StatusDot(color: failed ? .red : model.updatesAvailable ? .blue : .green,
                          text: "\(e.short)\(e.dirty ? "+" : "") · \(failed ? "Check failed" : model.engineMessage?.text ?? "Current")")
            }
            .lineLimit(1)
            .help("\(model.env?.repo ?? "") on \(e.branch)\n\(e.subject)\n\(model.engineMessage?.text ?? "")")
        } else {
            StatusDot(color: .red, text: model.env?.repo == nil ? "No engine" : "Not a git checkout")
        }
    }
}

struct MacAppCard: View {
    @Bindable var model: AppModel

    var body: some View {
        let _ = model.revision
        Card(title: "Mac app", subtitle: "Build settings for your native Mac application.") {
            HStack(spacing: 16) {
                GameIcon(url: model.game?.icon, size: 116)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.game?.name ?? "No game selected").font(.title2.weight(.bold)).lineLimit(2)
                    Text("Apple Silicon · Metal").foregroundStyle(.secondary)
                    Text("A native macOS version built with NxNative.").foregroundStyle(.secondary)
                }
            }
            PathField(label: "Output folder", labelWidth: 100, symbol: "folder", value: model.outputFolder?.lastComponent) {
                if let d = model.choose(folder: true, start: model.outputFolder) { model.settings.outDir = d == model.settings.gameDir ? nil : d }
            }
            .disabled(model.run.running)

            if model.run.running {
                HStack {
                    Button { } label: {
                        Label("Building…", systemImage: "hammer.fill").font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glassProminent).controlSize(.extraLarge).disabled(true)
                    Button("Stop") { model.run.cancel() }.buttonStyle(.glass).controlSize(.extraLarge)
                }
            } else {
                Button { model.build() } label: {
                    Label("Build Mac app", systemImage: "hammer.fill").font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.glassProminent).controlSize(.extraLarge)
                .disabled(!model.ready)
                .help(model.ready ? "" : !model.allOK ? "Some toolchain checks failed: see Toolchain" : "Choose a game folder and keys that validate")
            }

            Divider()
            if case .failure(let e)? = model.run.result {
                HStack(alignment: .top, spacing: 10) {
                    StatusDot(color: .red).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Build failed").font(.headline)
                        Text(e.description).font(.callout).foregroundStyle(.red).textSelection(.enabled).lineLimit(4)
                    }
                }
            }
            if let (app, b) = latestApp {
                let current = b.map { $0.engine.commit == model.engine?.commit && model.engine?.dirty == false } ?? false
                HStack(alignment: .top, spacing: 10) {
                    StatusDot(color: current ? .green : .orange).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current ? "Latest build ready" : "Built on an older engine").font(.headline)
                        Text(b.map { "\($0.date.map(relativeDay) ?? $0.builtAt) · Engine \($0.engine.short)" } ?? "Engine unknown: built before the converter recorded engines")
                            .foregroundStyle(.secondary).help(b?.engine.subject ?? "")
                    }
                }
                HStack {
                    Button { NSWorkspace.shared.open(app.url) } label: { Label("Open app", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    Button { reveal(app) } label: { Label("Show in Finder", systemImage: "folder").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.glass).controlSize(.large)
                if !current {
                    Button { model.build(rebuild: app) } label: {
                        Label("Rebuild on \(model.engine?.short ?? "the current engine")", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass).controlSize(.large).disabled(!model.ready)
                    .help(model.settings.keepBackups ? "Moves this app to app-backups/ and builds it again on the current engine" : "Builds this app again on the current engine; the old one goes to the Trash")
                }
            } else if !model.run.running {
                Text("No Mac app in this folder yet.").foregroundStyle(.secondary)
            }
        }
    }

    /// The newest game app in the game or output folder, with its recorded build.
    var latestApp: (String, BuildRecord?)? {
        let dirs = Set([model.settings.gameDir, model.settings.outDir].compactMap { $0 })
        let apps = dirs.flatMap { Engine.apps(in: $0) }
        let mt = { (p: String) in (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date ?? .distantPast }
        return apps.max { mt($0.app) < mt($1.app) }.map { ($0.app, $0.build) }
    }
}

struct ActivityCard: View {
    let model: AppModel

    var body: some View {
        let run = model.run
        Card {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Build activity").font(.title2.weight(.semibold))
                    Text("Converting your game to a native Mac application.").foregroundStyle(.secondary)
                }
                Spacer()
                state
                Button { copyToClipboard(model.logText) } label: { Label("Copy log", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.glass).disabled(run.log.isEmpty && run.done.isEmpty)
            }
            InsetTable {
                if run.done.isEmpty && !run.running {
                    ForEach(Array(stageNames.enumerated()), id: \.offset) { i, s in
                        if i > 0 { Divider() }
                        row(i + 1, state: nil, name: s.1, time: "–", status: "Not run", color: .secondary)
                    }
                } else {
                    ForEach(run.done) { s in
                        if s.k != run.done.first?.k { Divider() }
                        row(s.k, state: s.ok, name: friendly(s.name), time: mmss(s.seconds), status: !s.ok ? "Failed" : s.reused ? "Reused" : "Complete",
                            color: !s.ok ? .red : s.reused ? .secondary : .green)
                    }
                    if run.running {
                        if !run.done.isEmpty { Divider() }
                        HStack(spacing: 12) {
                            number(run.stage.k)
                            ProgressView().controlSize(.small).frame(width: 18)
                            Text(friendly(run.stage.name))
                            if !run.stage.step.isEmpty { Text("· \(run.stage.step)").foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                            Text(run.stage.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            if let f = run.stage.fraction { ProgressView(value: f).frame(width: 180) } else { ProgressView().progressViewStyle(.linear).frame(width: 180) }
                        }
                        .padding(.vertical, 6).padding(.horizontal, 10)
                    }
                }
            }
            HStack(spacing: 8) {
                if let s = run.done.first(where: { $0.name.hasPrefix("Mac shaders") }), let n = BuildRun.shaderCount(s) {
                    StatusDot(color: .green, text: "\(n) shaders ready")
                } else {
                    Image(systemName: "folder").foregroundStyle(.blue)
                    Text(model.settings.outDir == nil ? "Output saved beside your game files." : "Output saved to your selected folder.").foregroundStyle(.secondary)
                }
                Spacer()
                if !run.done.isEmpty && !run.running, run.result != nil {
                    Text("Total time: \(mmss(run.done.map(\.seconds).reduce(0, +)))").font(.callout).foregroundStyle(.secondary)
                }
            }
            if !run.log.isEmpty {
                DisclosureGroup("Log (\(run.log.count) lines)") {
                    ScrollView {
                        Text(run.log.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    /// The header's one-line state: ready, building, complete or failed.
    @ViewBuilder var state: some View {
        let run = model.run
        if run.running {
            HStack(spacing: 7) { ProgressView().controlSize(.small); Text("Building · step \(run.stage.k) of \(run.stage.n)").foregroundStyle(.secondary) }
        } else if let r = run.result {
            switch r {
            case .success: StatusDot(color: .green, text: "\(run.done.filter(\.ok).count) of \(run.done.last?.n ?? 7) complete")
            case .failure: StatusDot(color: .red, text: "Build failed")
            }
        } else {
            StatusDot(color: model.ready ? .green : .gray, text: model.ready ? "Ready to build" : "Not ready")
        }
    }

    func number(_ k: Int) -> some View {
        Text("\(k)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .frame(width: 22, height: 20).background(.quaternary, in: .rect(cornerRadius: 5))
    }

    func row(_ k: Int, state: Bool?, name: String, time: String, status: String, color: Color) -> some View {
        HStack(spacing: 12) {
            number(k)
            StatusIcon(ok: state, size: 17)
            Text(name)
            Spacer()
            Text(time).foregroundStyle(.secondary).monospacedDigit().frame(width: 50, alignment: .trailing)
            Text(status).foregroundStyle(color).frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 5).padding(.horizontal, 10)
    }
}
