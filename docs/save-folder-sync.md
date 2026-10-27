# Save Folder Sync

`DmSaveFolderSync` is an optional Files-provider bridge. The game continues to
run against its transactional `Documents/save` tree; the bridge reads that
host payload root directly and exports it after a successful host commit. The
guest save mount is already mapped by the host, so guest-relative paths must
not be appended to `Documents/save`.

The selected folder is held by a security-scoped bookmark. Sync uses
`<selected folder>/<title ID>/` and copies the committed `Documents/save`
contents directly beneath that title-ID directory. No emulator-specific
layout or intermediate save directory is added.

The bridge fingerprints file contents and relative paths rather than relying on
timestamps. Reads and staged replacements use `NSFileCoordinator` where the
provider supports it. Provider implementations may not make a directory swap
atomic, so staging and recovery copies protect the local save but cannot make a
remote Files provider transactional.

Automatic import/export retains the fingerprint, staging, recovery, and
conflict checks; divergent saves remain manual-resolution cases.

The public GameController API does not expose a portable Home/Guide button to
apps. Settings therefore use a one-second touch long-press and the documented
L+R+Plus two-second controller fallback; iOS 27 Home Button Overrides still
requires device validation and is not intercepted here.

## Validation and follow-up

The user confirmed the Save Folder Sync builds for both Metroid Dread and
Celeste working on iPhone. Their recorded source is
`a51aad6e0ae2fef570a94c05e5291fc0f3b5105e`; integration checkpoint
`validated/save-folder-sync-v1` contains this scoped implementation. Continue
polish work on `fix/save-sync-polish`. The original candidate IPAs, manifests,
and legacy source references remain preserved.
