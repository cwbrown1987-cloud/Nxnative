# NxNative Converter

A small Mac app over `scripts/build_ipa_from_nsp.py --platform mac-app`: it turns one game's folder into a native Mac app ([A Mac app](../docs/development.md#a-mac-app)) without the command line.

1. **Prerequisites.** It lists what the script needs, each ticked or crossed: Apple silicon, this repository and its shader translator, Xcode and its Metal toolchain, make and clang, .NET SDK 10, zstd, spirv-cross, a Python with lz4, capstone, fontTools and zstd, and macOS's codesign, sips and iconutil. glslang (OpenGL games) and nsz (`.nsz` / `.xcz` files) are optional. Tools are looked up as the script looks them up: its `TOOL_PATHS` first, then `PATH`, so a tick means the script finds the same tool. A crossed item has a **Fix in Terminal** button that runs the install command in a Terminal window.
2. **Game files.** Choose the game's folder (the base game, plus its update and DLC if you have them) and `prod.keys` (taken from the folder when it is there). **Validate** decrypts each NCA's header with `header_key`, works out the keys its key generation needs, decrypts the title key from the NSP's ticket (or the key area), and decrypts the start of a section to check it reads as a file system. It reads a few KB per file and takes under a second; no key value is shown or written anywhere, only key names.
3. **Convert.** **Build Mac app** runs the script with `--progress json` and shows its stages, then checks that the app's launcher is executable and that `codesign --verify --deep --strict` passes. The app is signed ad-hoc unless you pick a signing identity in Settings (`--mac-sign`).

**Engine and Rebuild.** The engine is the checkout the script runs from, and its git commit is the version a game is built with. The Engine section shows that commit and its branch, **Check for updates** fetches the branch's upstream, and **Update engine** fast-forwards to it (not with uncommitted changes in the checkout). Every build is recorded with its commit in `builds.json`, so the game apps in the chosen folder are listed with the engine each was built on: current, older, or unknown for an app built before the converter recorded engines. **Rebuild** moves that app to `app-backups/<name> (<old commit>, <time>).app` in the folder (a rename, so it takes no space), then runs the full conversion into the same path; the script reuses every stage whose inputs are unchanged, so a host-only engine change rebuilds the host and repacks. If the build fails, the old app is put back.

Settings (repository, Python, signing identity, last folder and keys path) are kept in `~/Library/Application Support/NxNative Converter/settings.json`. The repository is found from the setting, then the checkout the app was built in, then `~/Developer/nxnative`, `~/nxnative` and similar. Python is the setting, then `~/Library/Application Support/NxNative Converter/venv`, then the checkout's `.venv`, then each `python3` on `PATH`, the first with the modules winning.

## Build

Needs Rust (`rustup`):

```
app/bundle.sh
open "app/target/NxNative Converter.app"
```

The same steps run without the window, which is how it is tested:

```
app/target/release/nxnative-converter --check
app/target/release/nxnative-converter --validate "<game folder>" "<prod.keys>"
app/target/release/nxnative-converter --convert "<game folder>" "<prod.keys>" [--sign "<identity>"]
app/target/release/nxnative-converter --verify "<game>.app"
app/target/release/nxnative-converter --engine "<game folder>"
app/target/release/nxnative-converter --rebuild "<game folder>/<game>.app" "<prod.keys>" [--sign "<identity>"]
```

`NXC_SNAPSHOT=<file.png>` saves a picture of the window a few seconds after it opens and quits (with `NXC_PAGE=builds`, `toolchain` or `settings` for another page, and `NXC_AUTOBUILD=1` to build the chosen folder first), for checking the layout without a screen capture.
