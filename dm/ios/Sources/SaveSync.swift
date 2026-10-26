// Save sync folder for savesync_apple.m (DM_SAVE_SYNC): the player picks a folder once with the system folder picker (one in iCloud Drive, the same on every device). It is kept as a
// bookmark in UserDefaults, which lets the app back into that folder at every start with no entitlement or paid developer account. main.m resolves it at boot (dm_save_sync_folder)
// unless an env file set DM_SAVE_SYNC; the launcher's row changes or clears it before the game starts, when the host has not yet mounted the save
import SwiftUI
import UniformTypeIdentifiers

private let bookmarkKey = "saveSync.bookmark"

// The folder's path, its access held for the whole run (the host reads and writes it until the app quits); NULL when none is picked or the bookmark no longer works
@_cdecl("dm_save_sync_folder")
public func dmSaveSyncFolder() -> UnsafeMutablePointer<CChar>? {
    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale), url.startAccessingSecurityScopedResource() else {
        fputs("[RED] save sync: the sync folder cannot be opened any more; pick it again in the launcher\n", stderr)
        return nil
    }
    if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: bookmarkKey) }
    return strdup(url.path)
}

struct SaveSyncSection: View {
    private let locked = (ProcessInfo.processInfo.environment["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").contains("DM_SAVE_SYNC")
    @State private var folder = ProcessInfo.processInfo.environment["DM_SAVE_SYNC"].map { URL(fileURLWithPath: $0).lastPathComponent }
    @State private var picking = false

    var body: some View {
        Section {
            Button { picking = true } label: {
                HStack {
                    Text("Sync folder").foregroundStyle(.primary)
                    Spacer()
                    Text(folder ?? "Off").foregroundStyle(.secondary)
                }
            }
            if folder != nil && !locked { Button("Stop syncing", role: .destructive) { stop() } }
        } header: {
            Text("Save sync")
        } footer: {
            Text(locked ? "Set by an env file" : "Pick iCloud Drive → nxnative-saves, the folder the Mac app uses (open the Mac app once, or make the folder in the picker, if it is not there yet), to carry this game's save between them. If both sides changed, the game asks which save to keep.")
        }
        .disabled(locked)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            guard url.startAccessingSecurityScopedResource(), let data = try? url.bookmarkData() else { fputs("[RED] save sync: cannot keep access to \(url.path)\n", stderr); return }
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            setenv("DM_SAVE_SYNC", url.path, 1)
            folder = url.lastPathComponent
            fputs("save sync: folder \(url.path)\n", stderr)
        }
    }

    private func stop() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        unsetenv("DM_SAVE_SYNC")
        folder = nil
        fputs("save sync: off\n", stderr)
    }
}
