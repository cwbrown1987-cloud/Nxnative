#!/usr/bin/env bash
# Builds the self-contained "Pokemon Let's Go Pikachu.app": host binary, patched code, RomFS, shaders, fonts and
# profile tables all live inside the bundle, so the .app can be moved or copied anywhere without other folders.
# Data is cloned (APFS copy-on-write, no extra disk use) when the volume allows it, otherwise copied.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/010003F003A34000_build"
HOST="$HERE/../nxnative/dm/host/dmhost"
PROFILE="$HERE/../nxnative/dm/games/010003F003A34000"
DEFAULT_APP="$HERE/Pokémon Let's Go Pikachu.app"
APP="${1:-$DEFAULT_APP}"
SHADER_DIR="$(ls -d "$BUILD"/shader/ios/b-* | grep -v '\.key$' | head -1)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/game/shader/ios" "$APP/Contents/Resources/game/profile"
clone() { cp -cR "$1" "$2" 2>/dev/null || cp -R "$1" "$2"; }

cp "$HOST" "$APP/Contents/MacOS/dmhost"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
clone "$BUILD/patched_v131072" "$APP/Contents/Resources/game/patched_v131072"
clone "$BUILD/extract/v131072/RomFS" "$APP/Contents/Resources/game/RomFS"
clone "$BUILD/font" "$APP/Contents/Resources/game/font"
clone "$SHADER_DIR" "$APP/Contents/Resources/game/shader/ios/$(basename "$SHADER_DIR")"
cp "$PROFILE/shader_map.tsv" "$PROFILE/shader_map_alt.tsv" "$PROFILE/pso_manifest.tsv" "$APP/Contents/Resources/game/profile/"

cat > "$APP/Contents/MacOS/PokemonLetsGoPikachu" <<'LAUNCH'
#!/bin/bash
APP="$(cd "$(dirname "$0")/../.." && pwd)"
G="$APP/Contents/Resources/game"
DATA="$HOME/Library/Application Support/Pokemon Lets Go Pikachu"   # saves live outside the app so updating or moving it keeps them
mkdir -p "$DATA/save" "$DATA/temp"
export DM_WINDOW=1 DM_AUDIO=1 DM_OPMODE=0
export DM_ROOT="$DATA" DM_ROMFS="$G/RomFS" DM_SAVE="$DATA/save" DM_TEMP="$DATA/temp"
export DM_MSL_DIR="$G/shader/ios" DM_FONT_DIR="$G/font"
export DM_NVN_SHMAP="$G/profile/shader_map.tsv" DM_PSO_MANIFEST="$G/profile/pso_manifest.tsv" DM_PSO_USER="$DATA/pso_user.tsv"
exec "$APP/Contents/MacOS/dmhost" "$G/patched_v131072" >>"$DATA/log.txt" 2>&1
LAUNCH
chmod +x "$APP/Contents/MacOS/PokemonLetsGoPikachu" "$APP/Contents/MacOS/dmhost"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>PokemonLetsGoPikachu</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>org.nxnative.010003f003a34000</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Pokémon Let's Go Pikachu</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.2</string>
    <key>CFBundleVersion</key><string>1.0.2</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP/Contents/MacOS/dmhost" >/dev/null 2>&1 || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP ($(du -sh "$APP" | cut -f1))"
