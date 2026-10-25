#!/bin/bash
# Builds "NxNative Converter.app" from this package: swift build -c release, then a minimal bundle, signed ad-hoc
# (or with the identity in $SIGN). Usage: app/bundle.sh [output folder, default app/.build]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/.build}"
swift build -c release --package-path "$here"
app="$out/NxNative Converter.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$here/.build/release/NxNativeConverter" "$app/Contents/MacOS/"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NxNative Converter</string>
  <key>CFBundleDisplayName</key><string>NxNative Converter</string>
  <key>CFBundleIdentifier</key><string>org.nxnative.converter</string>
  <key>CFBundleExecutable</key><string>NxNativeConverter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --sign "${SIGN:--}" "$app"
echo "$app"
