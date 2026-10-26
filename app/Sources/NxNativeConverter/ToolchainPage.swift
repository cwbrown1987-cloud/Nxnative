// Toolchain: every tool the conversion needs in a grouped table, the engine checkout, and diagnostics.
import AppKit
import SwiftUI

struct ToolchainPage: View {
    @Bindable var model: AppModel
    @State private var advanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Toolchain", subtitle: "Everything needed to build native Mac apps.") {
                Button { model.recheck() } label: { Label("Run checks", systemImage: "arrow.clockwise").font(.title3) }
                    .buttonStyle(.glassProminent).controlSize(.extraLarge).disabled(model.checking)
            }

            Card(padding: 14) {
                HStack(spacing: 14) {
                    if model.checking { ProgressView().frame(width: 34) } else { StatusIcon(ok: model.allOK, size: 34) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.checking ? "Checking…" : model.allOK ? "Ready to build" : "Not ready to build").font(.headline)
                        Text(summary).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let t = model.lastChecked {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text("Last checked \(t.timeIntervalSinceNow > -60 ? "just now" : t.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            InsetTable {
                HStack {
                    Text("Tool").frame(width: 260, alignment: .leading)
                    Text("Version or location").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Status").frame(width: 190, alignment: .leading)
                }
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 9)
                ForEach(CheckGroup.allCases, id: \.self) { g in
                    let rows = (model.checks ?? []).filter { $0.group == g && !($0.group == .system && $0.name == "nxnative repository") }
                    if !rows.isEmpty {
                        Text(g.rawValue).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 7).background(.quaternary.opacity(0.5))
                        ForEach(rows) { c in
                            if c.id != rows.first?.id { Divider() }
                            row(c)
                        }
                    }
                }
            }

            Card(title: "Engine") {
                HStack(spacing: 12) {
                    Text("Version").foregroundStyle(.secondary)
                    if let e = model.engine {
                        Text(e.short).font(.body.monospaced()).help(e.label)
                        Text(model.updatesAvailable ? "Update available" : e.dirty ? "Local changes" : "Current").font(.callout)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background((model.updatesAvailable ? Color.blue : e.dirty ? .orange : .green).opacity(0.25), in: .capsule)
                            .foregroundStyle(model.updatesAvailable ? Color.blue : e.dirty ? .orange : .green)
                    } else {
                        Text(model.env?.repo == nil ? "No engine" : "Not a git checkout").foregroundStyle(.red)
                    }
                    Spacer().frame(width: 20)
                    Text("Source folder").foregroundStyle(.secondary)
                    Text(model.env?.repo?.tildePath ?? "Not found").lineLimit(1).truncationMode(.middle).help(model.env?.repo ?? "")
                    Spacer()
                    Button { if let d = model.choose(folder: true, start: model.env?.repo) { model.settings.repo = d; model.recheck() } } label: {
                        Label("Change folder", systemImage: "folder")
                    }
                    .buttonStyle(.glass)
                    if model.updatesAvailable {
                        Button { model.engineAction(update: true) } label: { Label("Update engine", systemImage: "arrow.down.circle") }
                            .buttonStyle(.glassProminent).disabled(model.engineBusy || model.run.running || model.engine?.dirty == true)
                    } else {
                        Button { model.engineAction(update: false) } label: { Label("Check for updates", systemImage: "arrow.clockwise") }
                            .buttonStyle(.glass).disabled(model.engineBusy || model.engine == nil)
                    }
                }
                if let m = model.engineMessage { Text(m.text).font(.callout).foregroundStyle(m.ok ? Color.secondary : Color.red) }
                if let repoCheck = model.checks?.first(where: { $0.name == "nxnative repository" }), !repoCheck.ok, let fix = repoCheck.fix {
                    HStack {
                        StatusDot(color: .red, text: "No nxnative checkout found")
                        Button("Clone it in Terminal") { Toolchain.runInTerminal(fix) }.buttonStyle(.glass)
                    }
                }
                Divider()
                DisclosureGroup(isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Python").frame(width: 120, alignment: .leading).foregroundStyle(.secondary)
                            Text((model.settings.python ?? model.env?.python)?.tildePath ?? "None with the modules").lineLimit(1).truncationMode(.middle)
                            if model.settings.python == nil { Text("found automatically").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if model.settings.python != nil { Button("Find automatically") { model.settings.python = nil; model.recheck() }.buttonStyle(.glass) }
                            Button("Choose…") { if let f = model.choose(folder: false) { model.settings.python = f; model.recheck() } }.buttonStyle(.glass)
                        }
                        advancedRow("DOTNET_ROOT", model.env?.dotnetRoot ?? "None")
                        advancedRow("Tool search path", model.env?.path ?? "")
                    }
                    .padding(.top, 8)
                } label: { Text("Advanced configuration").font(.headline) }
            }

            HStack {
                Spacer()
                Button { copyToClipboard(model.diagnostics) } label: { Label("Copy diagnostics", systemImage: "doc.on.clipboard") }.buttonStyle(.glass)
            }
        }
    }

    var summary: String {
        guard let c = model.checks else { return "Looking for the tools…" }
        let missing = c.filter { !$0.ok && !$0.optional }.map(\.name)
        return missing.isEmpty ? "All required tools are available." : "Missing: \(missing.joined(separator: ", "))."
    }

    func row(_ c: Check) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: c.symbol).font(.title3).foregroundStyle(.secondary).frame(width: 24)
                Text(c.name)
            }
            .frame(width: 260, alignment: .leading)
            Text(c.short).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).help(c.detail)
            HStack(spacing: 8) {
                if c.ok {
                    Image(systemName: "checkmark").foregroundStyle(.green).fontWeight(.semibold)
                    Text(c.optional ? "Available" : "Ready").foregroundStyle(.green)
                } else {
                    Image(systemName: c.optional ? "minus" : "xmark").foregroundStyle(c.optional ? Color.secondary : .red).fontWeight(.semibold)
                    Text(c.optional ? "Not installed" : "Missing").foregroundStyle(c.optional ? Color.secondary : .red)
                    if let fix = c.fix { Button("Fix") { Toolchain.runInTerminal(fix) }.buttonStyle(.glass).controlSize(.small).help(fix) }
                }
            }
            .frame(width: 190, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    func advancedRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).frame(width: 120, alignment: .leading).foregroundStyle(.secondary)
            Text(v).font(.callout.monospaced()).textSelection(.enabled).lineLimit(3)
            Spacer()
        }
    }
}
