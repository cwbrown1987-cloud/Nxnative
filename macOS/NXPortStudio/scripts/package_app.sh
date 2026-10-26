#!/bin/bash
# Build a portable app containing the GUI and an editable engine snapshot.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$PROJECT_DIR/../.." && pwd)"
OUTPUT="${1:-$PROJECT_DIR/dist/NX Port Studio.app}"

case "$OUTPUT" in
    *.app) ;;
    *) printf '%s\n' 'The output path must end in .app.' >&2; exit 1 ;;
esac
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
if [ -e "$OUTPUT" ]; then
    printf 'Output already exists: %s\nChoose another path or move the previous app first.\n' "$OUTPUT" >&2
    exit 1
fi

swift build --package-path "$PROJECT_DIR" --configuration release --arch arm64
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" --configuration release --arch arm64 --show-bin-path)"
RESOURCE_BUNDLE="$BIN_DIR/NXPortStudio_PortStudio.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    printf 'Missing SwiftPM resources: %s\n' "$RESOURCE_BUNDLE" >&2
    exit 1
fi

# Stage next to the destination so the final rename stays on the same volume.
STAGING="$(mktemp -d "$(dirname "$OUTPUT")/.nx-port-studio.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/NX Port Studio.app"
CONTENTS="$APP/Contents"
ENGINE="$CONTENTS/Resources/nxnative"
mkdir -p "$CONTENTS/MacOS" "$ENGINE"
cp "$BIN_DIR/NXPortStudio" "$CONTENTS/MacOS/NXPortStudio"
cp -R "$RESOURCE_BUNDLE" "$CONTENTS/Resources/"
ln -s ../Resources/NXPortStudio_PortStudio.bundle "$CONTENTS/MacOS/NXPortStudio_PortStudio.bundle"

# Keep the translator's checked-in dmsh_xlate_bin and third-party licenses.
# Generated compilers, game data, test fixtures and the GUI itself are omitted.
for SOURCE in dm scripts docs; do
    /usr/bin/rsync -a \
        --exclude='.git/' --exclude='.build/' --exclude='.swiftpm/' \
        --exclude='__pycache__/' --exclude='*.pyc' --exclude='.DS_Store' \
        --exclude='tests/' --exclude='test/' --exclude='obj/' --exclude='bin/' \
        --exclude='*.dSYM/' --exclude='*.partial' --exclude='*_build/' \
        --exclude='host/gen/' --exclude='ios/Gen/' --exclude='ios/DmIOS.xcodeproj/' \
        --exclude='host/dmhost' --exclude='host/dmhost_*' \
        "$REPO_DIR/$SOURCE" "$ENGINE/"
done
cp "$REPO_DIR/LICENSE" "$REPO_DIR/README.md" "$ENGINE/"

# Hash the actual snapshot, including local engine fixes. A changed snapshot gets
# a new Application Support directory even before a commit has been created.
ENGINE_HASH="$(/usr/bin/python3 - "$ENGINE" <<'PY'
import hashlib
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(root.rglob('*')):
    if path.is_dir():
        continue
    digest.update(path.relative_to(root).as_posix().encode('utf-8') + b'\0')
    digest.update(str(stat.S_IMODE(path.lstat().st_mode)).encode('ascii') + b'\0')
    if path.is_symlink():
        digest.update(str(path.readlink()).encode('utf-8'))
    else:
        with path.open('rb') as source:
            for block in iter(lambda: source.read(1024 * 1024), b''):
                digest.update(block)
    digest.update(b'\0')
print(digest.hexdigest()[:20])
PY
)"
BASE_REVISION="$(git -C "$REPO_DIR" rev-parse --short=12 HEAD 2>/dev/null || printf 'source')"
printf '%s-%s\n' "$BASE_REVISION" "$ENGINE_HASH" > "$ENGINE/ENGINE_REVISION"

xcrun swift "$PROJECT_DIR/scripts/GenerateIcon.swift" "$STAGING/AppIcon.iconset"
/usr/bin/iconutil -c icns "$STAGING/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>NX Port Studio</string>
    <key>CFBundleDisplayName</key><string>NX Port Studio</string>
    <key>CFBundleIdentifier</key><string>org.nxnative.portstudio</string>
    <key>CFBundleExecutable</key><string>NXPortStudio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>es</string>
    <key>CFBundleLocalizations</key><array><string>es</string><string>en</string></array>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"
# The default is a local ad-hoc signature. Developer ID distribution requires
# a separate signing/notarization review of the embedded tools and engine.
/usr/bin/codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$APP"
/usr/bin/codesign --verify "$APP"
mv "$APP" "$OUTPUT"
printf 'Created %s\nEngine snapshot: %s-%s\n' "$OUTPUT" "$BASE_REVISION" "$ENGINE_HASH"
