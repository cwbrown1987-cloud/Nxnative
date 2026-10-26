// Settings: appearance, notifications, where apps and keys come from, build behaviour and the build cache.
import AppKit
import SwiftUI

struct SettingsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Settings", subtitle: "Make NxNative Converter work your way.")
                form
            }
            .padding(24)
        }
    }

    @ViewBuilder var form: some View {
        Group {
            SettingsSection(title: "General") {
                setting("Appearance", "Choose how NxNative Converter looks.") {
                    Picker("", selection: $model.settings.appearance) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
                setting("Notify when a build finishes", "Show a notification when the build is complete.") {
                    Toggle("", isOn: $model.settings.notify).toggleStyle(.switch).labelsHidden()
                        .onChange(of: model.settings.notify) { _, on in if on { model.requestNotifications() } }
                }
                setting("Open app after building", "Automatically open the new app when the build completes.") {
                    Toggle("", isOn: $model.settings.openAfterBuild).toggleStyle(.switch).labelsHidden()
                }
                setting("Sign apps with", "Ad-hoc apps open on this Mac; a developer identity signs them as you.") {
                    Picker("", selection: $model.settings.signIdentity) {
                        Text("Ad-hoc (this Mac only)").tag(String?.none)
                        ForEach(model.identities, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            SettingsSection(title: "Files & folders") {
                setting("Default output location", "Where new Mac apps are saved.") {
                    Picker("", selection: Binding(get: { model.settings.outDir ?? "" }, set: { model.settings.outDir = $0.isEmpty ? nil : $0 })) {
                        Label("Alongside game files", systemImage: "folder").tag("")
                        if let o = model.settings.outDir { Label(o.lastComponent, systemImage: "folder").tag(o) }
                    }
                    .labelsHidden().fixedSize()
                    Button("Change…") { if let d = model.choose(folder: true, start: model.settings.outDir) { model.settings.outDir = d } }.buttonStyle(.glass)
                }
                setting("Default keys file", "Used for a game folder without its own prod.keys.") {
                    Picker("", selection: Binding(get: { model.settings.defaultKeys ?? "" }, set: { model.settings.defaultKeys = $0.isEmpty ? nil : $0 })) {
                        Text("None").tag("")
                        if let k = model.settings.defaultKeys { Text(k.tildePath).tag(k) }
                        if let k = model.settings.keys, k != model.settings.defaultKeys { Text(k.tildePath).tag(k) }
                    }
                    .labelsHidden().fixedSize()
                    Button("Choose…") { if let f = model.choose(folder: false) { model.settings.defaultKeys = f } }.buttonStyle(.glass)
                }
            }
            SettingsSection(title: "Builds") {
                setting("Reuse cached build steps", "Skip work when source files have not changed.") {
                    Toggle("", isOn: $model.settings.reuseCache).toggleStyle(.switch).labelsHidden()
                }
                setting("Keep previous app builds", "Save the existing app before replacing it.") {
                    Toggle("", isOn: $model.settings.keepBackups).toggleStyle(.switch).labelsHidden()
                }
                setting("Build logs", "Detailed adds each tool's own log to Copy log.") {
                    Picker("", selection: $model.settings.logDetail) {
                        ForEach(LogDetail.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            SettingsSection(title: "Storage") {
                setting("Build cache", model.buildCache.map { "\($0.tildePath). Reusable files can be regenerated on the next build." } ?? "Choose a game folder to see its cache.") {
                    Button { if let c = model.buildCache { reveal(c) } } label: { Label("Show in Finder", systemImage: "doc.text") }
                        .buttonStyle(.glass).disabled(model.buildCache == nil)
                    Button("Clear cache…") { clearCache() }.buttonStyle(.glass).disabled(model.buildCache == nil || model.run.running)
                }
            }
            Group {
                HStack {
                    Text("Settings are saved automatically.").foregroundStyle(.secondary)
                    Spacer()
                    Button { if model.confirm("Restore default settings?", "Appearance, notifications, output, keys, build and signing preferences go back to their defaults. Your game folder and engine stay.", action: "Restore") { model.settings.restoreDefaults(); model.recheck() } } label: {
                        Label("Restore defaults…", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    func setting<C: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            control()
        }
        .padding(.vertical, 3)
    }

    /// The whole <id>_build folder goes to the Trash: the next build extracts and compiles everything again.
    func clearCache() {
        guard let c = model.buildCache else { return }
        guard model.confirm("Clear the build cache?", "\(c.lastComponent) moves to the Trash. The next build extracts the game and compiles its shaders again, which takes much longer. Built apps are not affected.", action: "Move to Trash") else { return }
        try? FileManager.default.trashItem(at: c.url, resultingItemURL: nil)
        model.revision += 1
    }
}

/// A titled box of settings rows with hairlines between them, like a grouped form but full width.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.title3.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { i, v in
                    if i > 0 { Divider().padding(.leading, 16) }
                    v.padding(.horizontal, 16).padding(.vertical, 6)
                }
            }
        }
        .background(.background.secondary.opacity(0.7), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.7)))
    }
}
