"""Focused, platform-independent guard tests for the folder-sync contract."""
from pathlib import Path
import unittest

ROOT = Path(__file__).parents[3] / "dm" / "ios"
SYNC = (ROOT / "Sources" / "DmSaveFolderSync.m").read_text()
MAIN = (ROOT / "Sources" / "main.m").read_text()
FRONT = (ROOT / "Sources" / "front_ios.m").read_text()
LAUNCHER = (ROOT / "Sources" / "Launcher.swift").read_text()
GAME = (ROOT.parent / "games" / "game.py").read_text()


class SaveFolderSyncContractTests(unittest.TestCase):
    def test_title_id_is_the_only_game_folder_component(self):
        assert 'URLByAppendingPathComponent:self.titleID' in SYNC
        assert 'localPayloadURL' in SYNC
        assert 'externalPayloadURL' in SYNC
        assert 'SaveFolderSync-Recovery' not in SYNC.split('- (NSURL *)externalPayloadURL', 1)[1].split('- (NSURL *)gameFolder', 1)[0]
        assert 'localPayloadURL { return self.localSave; }' in SYNC
        assert 'URLByAppendingPathComponent:@"save"' not in SYNC
        assert 'titleID.length != 16' in SYNC
        assert "010093801237C000" not in SYNC
        assert "Yuzu" not in SYNC


    def test_local_save_remains_documents_save_and_commit_hook_is_connected(self):
        assert 'stringByAppendingPathComponent:@"save"' in MAIN
        assert '[g_folder_sync startBeforeGameplay]' in MAIN
        assert '[g_folder_sync saveCommitted]' in MAIN
        assert '@DM_GAME_TITLE_ID' in MAIN
        assert 'bundleIdentifier.lastPathComponent' not in MAIN
        assert 'DM_GAME_TITLE_ID' in GAME
        assert 'DM_GAME_SAVE_PATH' not in GAME


    def test_bookmarks_and_coordinated_external_access_are_present(self):
        assert 'kBookmark' in SYNC
        assert 'NSUserDefaults.standardUserDefaults dataForKey:kBookmark' in SYNC
        assert 'NSURLBookmarkResolutionWithoutUI' in SYNC
        assert 'NSURLBookmarkResolutionWithoutMounting' in SYNC
        assert 'bookmarkDataWithOptions:0' in SYNC
        assert 'NSURLBookmarkCreationWithSecurityScope' not in SYNC
        assert 'NSURLBookmarkResolutionWithSecurityScope' not in SYNC
        assert 'securityScopeActive' in SYNC
        assert 'Selected folder is unavailable; choose it again' in SYNC
        assert 'NSFileCoordinator' in SYNC


    def test_unified_settings_and_explicit_conflict_actions_are_present(self):
        assert 'SaveFolderSyncSection' in LAUNCHER
        assert 'Section("Save Folder Sync")' in LAUNCHER
        assert 'Save Sync Disabled' in LAUNCHER
        assert 'Save Sync Enabled' in LAUNCHER
        assert 'Tap to link folder' in LAUNCHER
        assert 'Tap to change folder' in LAUNCHER
        assert 'TitleID-named folder for Eden compatibility' in LAUNCHER
        assert "dm_save_folder_sync_clear" in LAUNCHER
        assert "Unlink selected folder" in LAUNCHER
        assert 'Unlink Save Folder?' in LAUNCHER
        assert "Sync Now" not in LAUNCHER
        assert "Save Format:" not in LAUNCHER
        assert "Use Folder Saves" in LAUNCHER
        assert "Use Device Saves" in LAUNCHER
        assert "Preserve Both" in LAUNCHER
        assert 'ForEach(m.settings.filter { $0.sectionTitle == section })' in LAUNCHER
        assert 'Reset to tested defaults' in LAUNCHER
        assert 'if let saveSync' in LAUNCHER
        assert 'DmSettingsViewController' not in LAUNCHER


    def test_external_game_directory_is_not_created_implicitly(self):
        assert 'createDirectoryAtURL:external withIntermediateDirectories:YES' not in SYNC
        assert 'replaceTree:local destination:external' in SYNC
        assert 'SaveFolderSync-Recovery' in SYNC


    def test_folder_selection_controls_enablement_and_clear_persistence(self):
        assert 'self.enabled = YES' in SYNC
        assert 'removeObjectForKey:kBookmark' in SYNC
        assert 'self.enabled = NO' in SYNC
        assert 'stopAccessingSecurityScopedResource' in SYNC
        assert 'Last successful sync' in LAUNCHER
        assert 'sync.statusText' in LAUNCHER
        assert 'restartRequired' not in SYNC
        assert SYNC.count('removeObjectForKey:kLocalFingerprint') >= 2


    def test_first_sync_reports_verified_direction_and_restart_requirement(self):
        assert SYNC.count('Save files imported successfully (%lu files).') == 2
        assert 'Restart the game to load your updated saves' not in SYNC
        assert 'Avoid saving in-game before restarting' not in SYNC
        assert 'Save files exported' in SYNC
        assert 'Already Up to Date' in SYNC
        assert 'Imported save verification failed' in SYNC
        assert 'Exported save verification failed' in SYNC
        assert 'if (!hasLocalBaseline || !hasExternalBaseline) [self syncOnQueue:NO];' in SYNC
        assert 'entries sortUsingComparator' in SYNC
        assert 'localChanged' in SYNC
        assert 'externalChanged' in SYNC
        assert 'Source save changed or disappeared during import' in SYNC
        assert 'Save file is present but not downloaded' in SYNC
        assert 'Different saves found on this device and in the selected folder. Choose which saves to use.' in SYNC
        assert 'NSFileCoordinator' in SYNC
        assert 'URLIsUbiquitousItemKey' in SYNC
        assert 'DmSaveFolderSyncFile' in SYNC
        assert 'preserved=' in SYNC
        assert 'backup:&localBackup' in SYNC
        assert 'backup:&externalBackup' in SYNC


    def test_legacy_icloud_synchronizer_and_warning_are_gone(self):
        assert 'GSSyncedDirectory' not in MAIN
        assert 'iCloud save freshness' not in MAIN
        assert 'iCloud save conflict' not in MAIN
        assert 'DmGameSaveNotice' not in FRONT
        assert 'triggerPendingUpload' not in MAIN
        assert 'DmSettingsViewController' not in FRONT
        assert 'DmOpenSettings' not in FRONT


    def test_recovery_is_deduplicated_bounded_and_payload_safe(self):
        assert 'kRecoverySnapshotLimit = 3' in SYNC
        assert '[localFP isEqualToString:externalFP]' in SYNC
        assert '@".stage-%@"' in SYNC
        assert 'while (snapshots.count > kRecoverySnapshotLimit)' in SYNC
        assert '[fm removeItemAtURL:oldest error:error]' in SYNC
        assert 'snapshot-%@-%@' in SYNC
        assert 'isReservedPayloadComponent' in SYNC
        assert 'localPayloadURL' in SYNC and 'externalPayloadURL' in SYNC


    def test_sync_status_reports_in_progress_last_success_and_operation(self):
        assert 'SaveSyncStatusLabel(state: saveSync.visualState)' in LAUNCHER
        assert 'Save Sync Details' in LAUNCHER
        assert 'Last successful sync' in LAUNCHER
        assert 'Last operation and result' in LAUNCHER
        assert 'Syncing saves…' in LAUNCHER
        assert 'Saves synchronized' in LAUNCHER
        assert 'Save conflict' in LAUNCHER
        assert 'Save sync unavailable' in LAUNCHER
        assert 'Save sync failed' in LAUNCHER
        assert 'model.enabled && model.configured' not in LAUNCHER
        assert 'if let saveSync, saveSync.showsStatus' in LAUNCHER
        assert 'UIApplication.didBecomeActiveNotification' in LAUNCHER
        assert 'if pendingResume { return .syncing }' in LAUNCHER
        assert 'status.hasPrefix("Save files imported successfully")' in LAUNCHER
        assert 'dm_save_folder_sync_now' not in LAUNCHER


    def test_save_sync_details_use_selected_folder_and_title_id_paths_with_copy_actions(self):
        assert 'url.resourceValues(forKeys: [.volumeNameKey])' in LAUNCHER
        assert 'getResourceValue(&volumeObject, forKey: .volumeURLKey)' in LAUNCHER
        assert 'folder.appendingPathComponent(titleID, isDirectory: true)' in LAUNCHER
        assert 'UIPasteboard.general.string = path' in LAUNCHER
        assert 'Provider-relative location from iOS Files' in LAUNCHER
        assert 'Location shown as exposed by iOS Files' in LAUNCHER
        assert 'Text(path)' in LAUNCHER
        assert '.fixedSize(horizontal: false, vertical: true)' in LAUNCHER


    def test_resume_checks_new_folder_sync_without_replacing_upstream_lifecycle(self):
        assert '[g_folder_sync resumeSafely]' in MAIN
        assert '[g_folder_sync saveCommitted]' in MAIN
