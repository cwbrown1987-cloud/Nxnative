#!/bin/bash
# Copy a game's files to its iPhone app's Documents/romfs once, so later installs built with DM_COPY_ROMFS=NO skip them (docs/development.md, Quick reinstalls).
# The marker goes last: main.m only takes a romfs whose marker exists, so a copy cut off halfway is never used.
# Usage: push_romfs.sh <device UDID> <bundle ID> <game>_build/xcode/Gen/resources.env
# Run it while the app (any build with that bundle ID) is installed. Rerun after a failure: unchanged files are skipped.
set -eu
dev=$1 id=$2; source "$3"
src=$DM_RESOURCE_ROMFS marker=$DM_RESOURCE_MARKER
stage=$(mktemp -d)/romfs
cp -cR "$src" "$stage"; rm "$stage/$marker"   # an APFS clone: no extra space
xcrun devicectl device copy to --device "$dev" --domain-type appDataContainer --domain-identifier "$id" --source "$stage" --destination Documents/romfs -q
xcrun devicectl device copy to --device "$dev" --domain-type appDataContainer --domain-identifier "$id" --source "$src/$marker" --destination "Documents/romfs/$marker" -q
echo "game files on the phone: $id"
