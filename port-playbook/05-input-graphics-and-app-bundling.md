# Chapter 5: Input, Graphics & App Bundling

This chapter covers controller input handling, keyboard mappings in Cocoa, Metal shader loading rules, and packaging the standalone double-clickable macOS `.app` bundle.

---

## 1. Controller Styles & Operation Modes

### The Handheld vs. Docked Dilemma
On Nintendo Switch, games query `nn::oe::GetOperationMode()`:
- `DM_OPMODE=0` -> **Handheld Mode**
- `DM_OPMODE=1` -> **Console / Docked Mode**

### Why *Pokémon: Let's Go* Required Handheld Mode
In Docked mode, the game explicitly **disables standard Pro Controllers** (`STYLE_FULLKEY`) and enforces physical single Joy-Con shaking for catching mechanics.
In Handheld mode (`DM_OPMODE=0`):
1. The game activates `STYLE_HANDHELD` (Npad ID `0x20`).
2. Both analog sticks, all face buttons, and shoulder buttons are fully active.
3. Catching Pokémon is performed with the **A Button** and Left Stick aiming, making keyboard and gamepad play seamless.

### Recommended `hle_hid.c` Controller Architecture
```c
static uint32_t style_of(uint32_t id) {
    if (dm_opmode() == 0) return id == NPAD_HANDHELD ? STYLE_HANDHELD : 0;
    if (id == NPAD_NO1) {
        // If the game does not support FullKey, fallback to supported styles
        if (g_styles_supported != 0xffffffffu && !(g_styles_supported & STYLE_FULLKEY)) {
            if (g_styles_supported & STYLE_JOYRIGHT) return STYLE_JOYRIGHT;
            if (g_styles_supported & STYLE_JOYLEFT) return STYLE_JOYLEFT;
            if (g_styles_supported & STYLE_HANDHELD) return STYLE_HANDHELD;
        }
        return STYLE_FULLKEY;
    }
    return 0;
}
```

---

## 2. Keyboard & Touch Input in `front_mac.m`

`nxnative/dm/host/front_mac.m` runs the Cocoa window and intercepts user events:

### Dual Movement (WASD + Arrow Keys)
Ensure that arrow keys also deflect the left analog stick so players can use either WASD or Arrows:

```objc
static int g_w, g_a, g_s, g_d;
static int g_up, g_down, g_left, g_right;

static void push(void) {
    int dx = (g_d || g_right) - (g_a || g_left);
    int dy = (g_w || g_up) - (g_s || g_down);
    int32_t lx = dx * 32767, ly = dy * 32767;
    dm_input_set(g_btn, lx, ly, 0, 0);
}
```

### Flexible Key Mapping
```objc
static int key_bit(unsigned short code) {
    switch (code) {
        // A Button: J, Space, C, E
        case 38: case 49: case 8: case 14: return 0;
        // B Button: K, X, Escape, Backspace
        case 40: case 7: case 53: case 51: return 1;
        // X Button: M, U, V
        case 46: case 32: case 9: return 2;
        // Y Button: Z, I
        case 6: case 34: return 3;
        // Stick clicks: F, G
        case 3: return 4;   case 5: return 5;
        // Shoulders: Q=L, R=R, 1=ZL, 2=ZR
        case 12: return 6;  case 15: return 7;
        case 18: return 8;  case 19: return 9;
        // Plus / Minus: P, Tab
        case 35: return 10; case 48: return 11;
        // D-Pad: Arrow keys
        case 123: return 12; case 126: return 13; case 124: return 14; case 125: return 15;
    }
    return -1;
}
```

---

## 3. Metal Shader Directory Rules

`dmhost` uses `DM_MSL_DIR` to find compiled `.metallib` files. 

### Critical Directory Rule:
`dmhost` internally appends `/b-<chain_version>` to `$DM_MSL_DIR`.
- **Incorrect:** `DM_MSL_DIR="/path/to/shader/ios/b-ef267d8c3195"` -> looks for `/shader/ios/b-ef267d8c3195/b-ef267d8c3195/` (fails!).
- **Correct:** `DM_MSL_DIR="/path/to/shader/ios"` -> resolves to `/shader/ios/b-ef267d8c3195/` (succeeds!).

---

## 4. macOS `.app` Bundle Creation

To produce a polished, native application that users can double-click in macOS Finder:

### Bundle Directory Structure
```
GameName.app/
  Contents/
    Info.plist
    PkgInfo
    MacOS/
      GameName (launcher script)
    Resources/
      AppIcon.icns
```

### Step 1: Generate Retina `AppIcon.icns`
```bash
ICON_SRC="/path/to/extracted/icon.jpg"
ICONSET="tmp_icons.iconset"
mkdir -p "$ICONSET"

# Generate all standard Retina icon resolutions (must use PNG format)
sips -s format png -z 16 16     "$ICON_SRC" --out "$ICONSET/icon_16x16.png"
sips -s format png -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png"
sips -s format png -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_32x32.png"
sips -s format png -z 64 64     "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png"
sips -s format png -z 128 128   "$ICON_SRC" --out "$ICONSET/icon_128x128.png"
sips -s format png -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png"
sips -s format png -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_256x256.png"
sips -s format png -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png"
sips -s format png -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_512x512.png"
sips -s format png -z 1024 1024 "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "AppIcon.icns"
rm -rf "$ICONSET"
```

### Step 2: Create `Info.plist`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>PokemonLetsGoPikachu</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>org.nxnative.010003f003a34000</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Pokémon Let's Go Pikachu</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.2</string>
    <key>CFBundleVersion</key>
    <string>1.0.2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

### Step 3: Write Launcher Script (`Contents/MacOS/PokemonLetsGoPikachu`)
```bash
#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

APP_BUNDLE="$(cd "$(dirname "$0")/../.." && pwd)"
PARENT_DIR="$(dirname "$APP_BUNDLE")"
BUILD_DIR="$PARENT_DIR/010003F003A34000_build"
DM_HOST="$PARENT_DIR/../nxnative/dm/host/dmhost"

export DM_WINDOW="${DM_WINDOW:-1}"
export DM_AUDIO="${DM_AUDIO:-1}"
export DM_OPMODE="${DM_OPMODE:-0}"
export DM_ROOT="$BUILD_DIR"
export DM_ROMFS="$BUILD_DIR/extract/v131072/RomFS"
export DM_SAVE="$BUILD_DIR/run/save"
export DM_TEMP="$BUILD_DIR/run/temp"
export DM_MSL_DIR="$BUILD_DIR/shader/ios"
export DM_FONT_DIR="$BUILD_DIR/font"

mkdir -p "$DM_SAVE" "$DM_TEMP"
exec "$DM_HOST" "$BUILD_DIR/patched_v131072" "$@"
```
Remember to run `chmod +x` on the launcher script.
