# NxNative Converter

A native Mac app (SwiftUI, macOS 26 or later) over `scripts/build_ipa_from_nsp.py --platform mac-app`: it turns one game's folder into a native Mac app ([A Mac app](../docs/development.md#a-mac-app)) without the command line. It needs only Xcode to build: the key check uses the system's CommonCrypto.

- **Convert.** Choose the game's folder (the base game, plus its update and DLC if you have them) and `prod.keys` (taken from the folder when it is there, else the default keys file from Settings). The converter checks the files against the keys in under a second: it decrypts each NCA's header with `header_key`, the title key from the NSP's ticket with `titlekek_XX` (or the key area with `key_area_key_*_XX`), and the first bytes of a section, which must read as PFS0 or RomFS. NSZ and XCZ files get the header and key checks; the build checks their data. No key value is shown, logged or stored, only key names. **Build Mac app** runs the script with `--progress json`, shows its seven stages, then checks that the app's launcher is executable and that `codesign --verify --deep --strict` passes. The app goes beside the game files, or to the output folder you choose.
- **Builds.** Every app the converter built, with the engine commit it was built on. The engine is the nxnative checkout the script runs from; the bundle carries no commit, so each build is recorded in `~/Library/Application Support/NxNative Converter/builds.json`. **Rebuild** moves the app to `app-backups/<name> (<commit>, <time>).app` in its folder (a rename, no space taken), runs the full script into the same path (stages with unchanged inputs are reused, so a host-only engine change rebuilds the host and repacks), and puts the old app back if the build fails. **Previous builds** lists those kept copies, to open, restore or move to the Trash. One build per game folder runs at a time (`.nxnative-converter.lock`).
- **Toolchain.** Each tool the script needs, found as the script finds it: its own `TOOL_PATHS` first, then `PATH`, so a tick means the script finds the same tool. The shader translator is started, not just found: its launcher finds .NET only through `DOTNET_ROOT`, which the converter sets to the folder of the `dotnet` the script uses. A missing tool's **Fix** runs its install command in Terminal. The engine section shows the checkout's commit, **Check for updates** fetches its branch's upstream and **Update engine** fast-forwards to it. **Copy diagnostics** copies the findings (paths and versions, no key values).
- **Settings.** Appearance, a notification when a build ends, opening the app after a build, the signing identity (`--mac-sign`; ad-hoc by default), the default output folder and keys file, reusing cached stages (off deletes the stage keys in `<id>_build`, so every stage runs again), keeping previous builds (off moves the replaced app to the Trash), log detail (Detailed adds the tools' own logs to Copy log) and the game's build cache.

Settings are in `~/Library/Application Support/NxNative Converter/settings.json`. The repository is found from the setting, then the checkout the app was built in, then `~/Developer/nxnative`, `~/nxnative` and similar. Python is the setting, then `~/Library/Application Support/NxNative Converter/venv`, then the checkout's `.venv`, then each `python3` on `PATH`, the first with the modules winning.

## Build

```
app/bundle.sh
open "app/.build/NxNative Converter.app"
```

The same steps run without the window, which is how it is tested:

```
app/.build/release/NxNativeConverter --check
app/.build/release/NxNativeConverter --validate "<game folder>" "<prod.keys>"
app/.build/release/NxNativeConverter --convert "<game folder>" "<prod.keys>" [--sign "<identity>"]
app/.build/release/NxNativeConverter --rebuild "<game folder>/<game>.app" "<prod.keys>" [--sign "<identity>"]
app/.build/release/NxNativeConverter --engine "<game folder>"
app/.build/release/NxNativeConverter --verify "<game>.app"
```

For checking the window: `NXC_SNAPSHOT=<file.png>` saves a picture of it a few seconds after it opens, writes its window number to `<file.png>.wid` for `screencapture -l`, and quits (`NXC_PAGE=builds`, `toolchain` or `settings` for another page; `NXC_AUTOBUILD=1` builds the chosen folder first). `NXC_SUPPORT_DIR=<folder>` keeps settings and build records there instead, to test beside a copy in use.
