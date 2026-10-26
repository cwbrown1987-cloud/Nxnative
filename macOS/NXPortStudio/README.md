# NX Port Studio

A native macOS interface for nxnative. Select your own game folder and `prod.keys`, choose a Mac app or an iPhone/iPad build, and follow the engine's real build progress. The interface is in Spanish; technical tool output retains its original language. Mac apps are written to Downloads by default; the output folder can be changed.

The GUI drives the existing `scripts/build_ipa_from_nsp.py` pipeline. It does not add game compatibility beyond the engine's profiles, and an untested title or update may produce a port that does not start.

## Build and package

The GUI requires an Apple silicon Mac, macOS 14 or later and Xcode with Swift 6. The game engine has its own Xcode/Metal, .NET and Python dependencies; inspect them in the app's Environment view before building a game. Some games require newer macOS/Metal versions than the GUI itself.

From this directory:

```sh
swift test
swift run NXPortStudio
./scripts/package_app.sh "/path/to/NX Port Studio.app"
```

Without an output argument, the package script creates `dist/NX Port Studio.app`. It refuses to replace an existing app. The script compiles a release arm64 executable, creates the app icon from Swift drawing code and applies a local ad-hoc signature. It does not produce a notarized distribution. `CODE_SIGN_IDENTITY` can select another available identity, but Developer ID distribution still requires a review of the embedded tools and signing requirements.

The app includes an engine snapshot under `Contents/Resources/nxnative`. On first launch it copies that snapshot to `~/Library/Application Support/NX Port Studio/Engine/<revision>/`, where nxnative can write its generated files. The revision combines the source commit and a digest of the actual packaged engine, so local engine fixes create a fresh snapshot as well. Build products and extracted game files remain beside the input game's folder, following nxnative's normal cache layout.

The package includes the engine's `dm`, `scripts`, `docs`, `README.md` and `LICENSE`, including third-party licenses. It excludes Git metadata, the GUI's source/build directory, Python caches, test directories and generated compiler/build output. A source checkout can also be selected in Environment.

## Keys and game inputs

Choose a folder containing one game's base NSP/XCI and any matching update/DLC. NSZ/XCZ inputs require the additional `nsz` Python module. You provide the game files and keys; none are included with the app.

Selecting a keys file remembers its path. Pasting keys stores a local file in the app's Application Support directory with owner-only permissions. Keys are passed to local build tools by path and their values are never printed by the GUI. The app neither uploads keys nor includes them in its engine snapshot.

## Install on iPhone or iPad

Choose the iPhone/iPad destination and the installation mode to prepare the per-game Xcode project. Select a discovered device and your Apple development Team ID, then use the installation action. The service builds a signed app with Xcode and installs it through `xcrun devicectl`. It does not ask for or store an Apple account password; configure the account and signing access in Xcode.

Apple requires device trust/pairing, Developer Mode and a valid provisioning profile. Pair a device with the Mac by USB first; a previously paired device can appear over Wi-Fi when Xcode's network connection is available and the network permits it. Physical proximity by itself does not provide wireless installation. If Apple requests a device-side approval, complete it on the device. Provisioning can contact Apple's servers during the explicit installation action.

An exported IPA is unsigned and needs a signing/sideloading tool before it can be installed. The direct installation path uses the prepared Xcode project instead. Large games can exceed storage, memory or installer limits even on a supported device. nxnative currently documents iOS/iPadOS 26 or later, iPhone 15 Pro/A17 Pro or newer, or an M1-or-newer iPad for its BC-compressed texture support; check the current engine documentation for each game's restrictions.

## Validation scope

Unit tests exercise argument construction, progress decoding, process handling and device response parsing with synthetic fixtures. These checks do not establish game execution or device installation compatibility. End-to-end conversion and installation require your game files, keys and an appropriately configured physical device.

Engine documentation: [nxnative](https://github.com/seedds/nxnative), [development guide](../../docs/development.md), [AppleGamingWiki guide](https://www.applegamingwiki.com/wiki/Nxnative_Switch_to_Mac_conversion).
