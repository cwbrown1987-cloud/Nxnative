// Builds: every app the converter built, a detail panel for the selected one, and the copies a rebuild kept.
import AppKit
import SwiftUI

struct BuildsPage: View {
    @Bindable var model: AppModel

    var builds: [BuildRecord] {
        let _ = model.revision
        var b = Engine.builds().filter { FileManager.default.fileExists(atPath: $0.app) }
        let q = model.buildSearch.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { b = b.filter { name($0).lowercased().contains(q) || $0.engine.short.contains(q) } }
        switch model.buildSort {
        case .newest: b.sort { $0.builtAt > $1.builtAt }
        case .oldest: b.sort { $0.builtAt < $1.builtAt }
        case .name: b.sort { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        }
        return b
    }

    func name(_ b: BuildRecord) -> String { b.app.url.deletingPathExtension().lastPathComponent }

    var body: some View {
        let list = builds
        let selected = list.first { $0.app == model.selectedBuild } ?? list.first
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Builds", subtitle: "Your native Mac apps, ready to play.") {
                    Picker("Sort", selection: $model.buildSort) {
                        ForEach(BuildSort.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.menu).fixedSize()
                }
                if list.isEmpty {
                    Card { Text(model.buildSearch.isEmpty ? "Nothing built yet. Convert a game to see it here." : "No builds match “\(model.buildSearch)”.").foregroundStyle(.secondary) }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        Card(padding: 8) {
                            VStack(spacing: 4) {
                                ForEach(list) { b in
                                    BuildRow(model: model, build: b, name: name(b), selected: b.app == selected?.app)
                                        .onTapGesture { model.selectedBuild = b.app }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        if let s = selected { BuildDetail(model: model, build: s, name: name(s)).frame(maxWidth: .infinity) }
                    }
                    if let s = selected { PreviousBuilds(model: model, build: s) }
                }
            }
            .padding(24)
        }
    }
}

struct BuildRow: View {
    let model: AppModel
    let build: BuildRecord
    let name: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 14) {
            AppIcon(path: build.app, size: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.title3.weight(.semibold)).lineLimit(2)
                Text(build.date.map(relativeDay) ?? build.builtAt).foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                StatusDot(color: .green, text: "Ready")
                Text("Apple Silicon").foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
        }
        .padding(10)
        .foregroundStyle(selected ? .white : .primary)
        .background(selected ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
        .contentShape(.rect)
    }
}

struct BuildDetail: View {
    @Bindable var model: AppModel
    let build: BuildRecord
    let name: String
    @State private var detailsOpen = true

    var body: some View {
        let current = build.engine.commit == model.engine?.commit && model.engine?.dirty == false
        Card {
            HStack(spacing: 16) {
                AppIcon(path: build.app, size: 128)
                VStack(alignment: .leading, spacing: 5) {
                    Text(name).font(.title.weight(.bold)).lineLimit(2)
                    Text("Apple Silicon · Metal").foregroundStyle(.secondary)
                    StatusDot(color: .green, text: "Ready")
                }
            }
            HStack {
                Button { NSWorkspace.shared.open(build.app.url) } label: { Label("Open app", systemImage: "play.fill").font(.title3).frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent)
                Button { reveal(build.app) } label: { Label("Show in Finder", systemImage: "folder").frame(maxWidth: .infinity) }
                    .buttonStyle(.glass)
            }
            .controlSize(.extraLarge)
            VStack(spacing: 0) {
                detail("Built", build.date.map(relativeDay) ?? build.builtAt)
                Divider()
                HStack {
                    Text("Engine").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    Text(build.engine.short).help(build.engine.subject)
                    if !current, model.engine != nil { Text("older").font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.orange.opacity(0.25), in: .capsule) }
                    Spacer()
                }
                .padding(.vertical, 8)
                Divider()
                detail("Game files", build.gameFiles ?? Engine.describeFiles(build.gameDir))
                Divider()
                HStack {
                    Text("Location").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    Text(build.app.url.deletingLastPathComponent().path.tildePath).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { reveal(build.app) } label: { Image(systemName: "folder") }.buttonStyle(.glass)
                }
                .padding(.vertical, 6)
            }
            Button { model.rebuild(build) } label: {
                Label(current ? "Rebuild app" : "Rebuild on \(model.engine?.short ?? "the current engine")", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass).controlSize(.large)
            .disabled(!model.allOK || model.run.running)
            DisclosureGroup(isExpanded: $detailsOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { StatusIcon(ok: build.steps.map { $0 > 0 }); Text(build.steps.map { "\($0) steps completed" } ?? "Steps not recorded") }
                    HStack { StatusIcon(ok: build.shaders == nil ? nil : true); Text(build.shaders.map { "\($0) Metal shaders ready" } ?? "Metal shaders ready") }
                    Text(build.engine.subject).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.top, 6)
            } label: { Text("Build details").font(.headline) }
        }
    }

    func detail(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(v).lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

struct PreviousBuilds: View {
    let model: AppModel
    let build: BuildRecord

    var body: some View {
        let _ = model.revision
        let backups = Engine.backups(of: build.app)
        Card(title: "Previous builds", subtitle: "Older versions of this game's native app.") {
            if backups.isEmpty {
                Text("None kept. A rebuild keeps the old app here\(model.settings.keepBackups ? "" : " when Keep previous app builds is on in Settings").").foregroundStyle(.secondary)
            } else {
                InsetTable {
                    HStack {
                        Text("Built").frame(width: 170, alignment: .leading)
                        Text("Engine").frame(width: 110, alignment: .leading)
                        Text("Game files").frame(width: 170, alignment: .leading)
                        Text("Location")
                        Spacer()
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6).background(.quaternary.opacity(0.4))
                    ForEach(backups) { b in
                        Divider()
                        HStack {
                            Text(b.date.map(relativeDay) ?? "Unknown").frame(width: 170, alignment: .leading)
                            Text(b.engine).frame(width: 110, alignment: .leading)
                            Text(build.gameFiles ?? Engine.describeFiles(build.gameDir)).frame(width: 170, alignment: .leading)
                            Text(b.path.url.deletingLastPathComponent().path.tildePath).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { reveal(b.path) } label: { Label("Show in Finder", systemImage: "folder") }.buttonStyle(.glass)
                            Menu {
                                Button("Open") { NSWorkspace.shared.open(b.path.url) }
                                Button("Restore this version") { restore(b) }
                                Divider()
                                Button("Move to Trash") {
                                    try? FileManager.default.trashItem(at: b.path.url, resultingItemURL: nil)
                                    model.revision += 1
                                }
                            } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.button).buttonStyle(.glass).fixedSize()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                }
            }
        }
    }

    /// Swap a kept copy back in: the current app goes to app-backups/ in its place.
    func restore(_ b: Backup) {
        guard model.confirm("Restore this version?", "The current app moves to app-backups and this copy takes its place.", action: "Restore") else { return }
        let current = Engine.builds().first { $0.app == build.app }?.engine
        do {
            _ = try Engine.backUp(build.app, engine: current)
            try FileManager.default.moveItem(atPath: b.path, toPath: build.app)
            // the record now describes the restored copy: its engine is the one its backup name carries
            var r = build
            r.engine = EngineVersion(commit: b.engine, subject: "Restored from app-backups", date: "", branch: "", dirty: false)
            r.builtAt = b.date.map { d in let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: d) } ?? build.builtAt
            r.steps = nil; r.shaders = nil
            Engine.record(r)
        } catch {
            _ = model.confirm("Could not restore", "\(error)", action: "OK")
        }
        model.revision += 1
    }
}
