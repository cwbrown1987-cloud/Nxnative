#!/bin/bash
# Builds "NxNative Converter.app" from this crate: cargo build --release, then a minimal bundle, signed ad-hoc
# (or with the identity in $SIGN). Usage: app/bundle.sh [output folder, default app/target]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/target}"
cargo build --release --manifest-path "$here/Cargo.toml"
app="$out/NxNative Converter.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$here/target/release/nxnative-converter" "$app/Contents/MacOS/"
version="$(sed -n 's/^version = "\(.*\)"/\1/p' "$here/Cargo.toml" | head -1)"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NxNative Converter</string>
  <key>CFBundleDisplayName</key><string>NxNative Converter</string>
  <key>CFBundleIdentifier</key><string>org.nxnative.converter</string>
  <key>CFBundleExecutable</key><string>nxnative-converter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --sign "${SIGN:--}" "$app"
echo "$app"
