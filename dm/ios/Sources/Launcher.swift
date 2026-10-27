// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json, which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section. Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once, as an app without launcher.json does
import SwiftUI
import UIKit
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }

private extension LauncherModel {
    func binding(_ s: Setting) -> Binding<String> { Binding(get: { self.values[s.env] ?? s.def }, set: { self.values[s.env] = $0 }) }
}

private struct SettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel

    private var locked: Bool { m.fromFile.contains(s.env) }
    private var note: String {
        locked ? (s.note.isEmpty ? "" : s.note + " · ") + "Set by an env file" : s.note
    }
    private var rangeValue: Binding<Double> {
        Binding(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 },
                set: { m.values[s.env] = String(format: "%.2f", $0) })
    }
    private var percentage: String { "\(Int((rangeValue.wrappedValue * 100).rounded())) %" }

    private var settingLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.label)
            if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    var body: some View {
        Group {
            switch s.kind {
            case "choice":
                Picker(selection: m.binding(s)) {
                    ForEach(s.options ?? [], id: \.[0]) { Text($0[1]).tag($0[0]) }
                } label: {
                    settingLabel
                }
                .pickerStyle(.menu)
            case "range":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        settingLabel
                        Spacer()
                        Text(percentage).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: rangeValue, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05)
                        .accessibilityLabel(s.label)
                        .accessibilityValue(percentage)
                }
            default:
                Toggle(isOn: Binding(get: { (m.values[s.env] ?? s.def) == s.onValue }, set: { m.values[s.env] = $0 ? s.onValue : s.offValue })) {
                    settingLabel
                }
            }
        }
        .disabled(locked)
    }
}

private final class SaveFolderSyncModel: ObservableObject {
    let sync: DmSaveFolderSync
    @Published private(set) var revision = 0
    @Published private(set) var pendingResume = false
    private var notice: NSObjectProtocol?
    private var active: NSObjectProtocol?

    init?(_ sync: DmSaveFolderSync?) {
        guard let sync else { return nil }
        self.sync = sync
        notice = NotificationCenter.default.addObserver(forName: Notification.Name(rawValue: DmSaveFolderSyncNotice), object: nil, queue: .main) { [weak self] _ in
            self?.pendingResume = false
            self?.revision += 1
        }
        active = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.showsStatus else { return }
            self.pendingResume = true
            self.revision += 1
        }
    }

    deinit {
        if let notice { NotificationCenter.default.removeObserver(notice) }
        if let active { NotificationCenter.default.removeObserver(active) }
    }

    var folderName: String { sync.selectedFolderName ?? "Sync Folder" }
    var titleID: String { sync.titleID }
    var status: String { sync.statusText ?? "No folder selected" }
    var lastSync: String { sync.lastSuccessfulSync?.formatted(date: .abbreviated, time: .shortened) ?? "Never" }
    var configured: Bool { sync.selectedFolder != nil }
    var enabled: Bool { sync.enabled }
    var showsStatus: Bool { configured && (enabled || status == "Syncing") }
    var unavailable: Bool { sync.state.rawValue == 3 || sync.state.rawValue == 4 }
    var conflict: Bool { sync.state.rawValue == 2 }
    var visualState: SaveSyncVisualState {
        if conflict { return .conflict }
        if sync.state.rawValue == 3 { return .unavailable }
        if sync.state.rawValue == 4 { return .failed }
        if status == "Syncing" { return .syncing }
        if pendingResume { return .syncing }
        if sync.lastSuccessfulSync != nil,
           status == "Already Up to Date" || status.hasPrefix("Save files imported successfully") || status.hasPrefix("Save files exported") { return .ready }
        // A newly resolved sync object starts at "Ready" before its first status notice.
        // Do not treat that default as evidence that the current launch is synchronized.
        return .syncing
    }
    private func displayPath(_ url: URL) -> (String, Bool) {
        let path = url.standardizedFileURL.path
        do {
            let values = try url.resourceValues(forKeys: [.volumeNameKey])
            var volumeObject: AnyObject?
            try (url as NSURL).getResourceValue(&volumeObject, forKey: .volumeURLKey)
            if let volumeURL = volumeObject as? NSURL,
               let root = volumeURL.path,
               let volumeName = values.volumeName, !volumeName.isEmpty {
                let prefix = root.hasSuffix("/") ? root : root + "/"
                if path.hasPrefix(prefix) {
                    let relative = String(path.dropFirst(prefix.count))
                    if !relative.isEmpty { return ("\(volumeName)/\(relative)", true) }
                }
            }
        } catch { }
        return (path, false)
    }
    var linkedFolderPath: String? {
        guard let folder = sync.selectedFolder else { return nil }
        let (path, _) = displayPath(folder)
        return path.hasSuffix("/") ? path : path + "/"
    }
    var saveDestinationPath: String? {
        guard let folder = sync.selectedFolder else { return nil }
        let destination = folder.appendingPathComponent(titleID, isDirectory: true)
        let (folderPath, providerRelative) = displayPath(folder)
        let path = providerRelative ? folderPath + "/" + titleID : destination.standardizedFileURL.path
        return path.hasSuffix("/") ? path : path + "/"
    }
    var pathNote: String {
        guard let folder = sync.selectedFolder else { return "" }
        let (_, providerRelative) = displayPath(folder)
        return providerRelative ? "Provider-relative location from iOS Files" : "Location shown as exposed by iOS Files"
    }

    func refresh() { revision += 1 }
}

private enum SaveSyncVisualState: Equatable {
    case ready, syncing, conflict, unavailable, failed

    var title: String {
        switch self {
        case .ready: return "Saves synchronized"
        case .syncing: return "Syncing saves…"
        case .conflict: return "Save conflict"
        case .unavailable: return "Save sync unavailable"
        case .failed: return "Save sync failed"
        }
    }
    var color: Color {
        switch self {
        case .ready: return .green
        case .syncing: return .orange
        case .conflict, .unavailable, .failed: return .red
        }
    }
    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .syncing: return "arrow.2.circlepath"
        case .conflict, .unavailable, .failed: return "exclamationmark.triangle.fill"
        }
    }
}

private struct SaveSyncStatusLabel: View {
    let state: SaveSyncVisualState
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.symbol)
                .rotationEffect(.degrees(state == .syncing ? 360 : 0))
                .animation(state == .syncing ? .linear(duration: 1.1).repeatForever(autoreverses: false) : .default, value: state == .syncing)
            Text(state.title).lineLimit(2).multilineTextAlignment(.center)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(state.color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.title)
    }
}

private struct SaveSyncDetailsView: View {
    @ObservedObject var model: SaveFolderSyncModel
    @Environment(\.dismiss) private var dismiss
    @State private var copiedPath: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SaveSyncStatusLabel(state: model.visualState)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    detailRow(title: "Last successful sync", value: model.lastSync)
                    detailRow(title: "Last operation and result", value: model.status)
                    if let path = model.linkedFolderPath {
                        pathRow(title: "Linked folder", path: path)
                    }
                    if let path = model.saveDestinationPath {
                        pathRow(title: "Save destination", path: path)
                    }
                    Text(model.pathNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Save Sync Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func detailRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func pathRow(title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                Text(path)
                    .font(.footnote.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = path
                    copiedPath = path
                } label: {
                    Image(systemName: copiedPath == path ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy \(title.lowercased()) path")
            }
        }
    }
}

private struct SaveFolderSyncSection: View {
    @ObservedObject var model: SaveFolderSyncModel
    let presenter: () -> UIViewController?
    @State private var resolvingConflict = false
    @State private var confirmingUnlink = false

    var body: some View {
        Section("Save Folder Sync") {
            HStack(spacing: 8) {
                Button {
                    if let viewController = presenter() { dm_save_folder_sync_present(model.sync, viewController) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.enabled || (model.configured && model.status == "Syncing") ? "Save Sync Enabled" : "Save Sync Disabled")
                        Text(model.enabled || (model.configured && model.status == "Syncing") ? "\(model.folderName) · Tap to change folder" : model.configured ? "\(model.folderName) · Tap to enable or change folder" : "Tap to link folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                if model.configured {
                    Button {
                        confirmingUnlink = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Unlink selected folder")
                }
            }
            Text("Automatically syncs saves to a shared folder. Saves are stored in a TitleID-named folder for Eden compatibility.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if model.conflict {
                Button("Resolve Save Conflict…") { resolvingConflict = true }
            }
        }
        .confirmationDialog("Resolve Conflicts", isPresented: $resolvingConflict) {
            Button("Use Folder Saves") { dm_save_folder_sync_import(model.sync) }
            Button("Use Device Saves") { dm_save_folder_sync_export(model.sync) }
            Button("Preserve Both", role: .cancel) { dm_save_folder_sync_preserve(model.sync) }
        } message: {
            Text("Both local and folder saves changed. Choose which complete save to keep.")
        }
        .confirmationDialog("Unlink Save Folder?", isPresented: $confirmingUnlink, titleVisibility: .visible) {
            Button("Unlink Folder", role: .destructive) {
                dm_save_folder_sync_clear(model.sync)
                model.refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the folder link only. Save files in both locations will be kept.")
        }
    }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let saveSync: SaveFolderSyncModel?
    let presenter: () -> UIViewController?
    let play: () -> Void
    @State private var memory = os_proc_available_memory()
    @State private var showingSaveSyncDetails = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 16) {
                    if let icon = appIcon() {
                        Image(uiImage: icon).resizable().frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .accessibilityHidden(true)
                    }
                    Text((info("CFBundleDisplayName") as? String) ?? "Game")
                        .font(.title.weight(.bold)).multilineTextAlignment(.center)
                    Text("Version \((info("CFBundleShortVersionString") as? String) ?? "")")
                        .font(.callout).foregroundStyle(.secondary)
                    playButton
                    if let saveSync, saveSync.showsStatus {
                        Button { showingSaveSyncDetails = true } label: {
                            SaveSyncStatusLabel(state: saveSync.visualState)
                                .frame(maxWidth: 240)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens Save Sync Details")
                    }
                }
                .padding(16)
                .frame(width: geometry.size.width / 3, height: geometry.size.height)
                List {
                    ForEach(m.sections, id: \.self) { section in
                        Section(section) {
                            ForEach(m.settings.filter { $0.sectionTitle == section }) { SettingRow(s: $0, m: m) }
                        }
                    }
                    Section {
                        Button("Reset to tested defaults") { m.reset() }
                            .disabled(!m.changed)
                    } footer: {
                        Text("Brings back all settings this game was tested with.")
                    }
                    if let saveSync { SaveFolderSyncSection(model: saveSync, presenter: presenter) }
                    Section {
                        HStack {
                            Text("Memory available")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .contentMargins(.horizontal, 12, for: .scrollContent)
                .frame(width: geometry.size.width * 2 / 3)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSaveSyncDetails) {
            if let saveSync { SaveSyncDetailsView(model: saveSync) }
        }
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: play) { Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: 220) }.controlSize(.large)
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }

    private func appIcon() -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); return false }
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let model = LauncherModel(file.settings)
    let saveSync = SaveFolderSyncModel(dm_save_folder_sync())
    var host: UIViewController?
    let view = LauncherView(m: model, saveSync: saveSync, presenter: { host }) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = UIHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
