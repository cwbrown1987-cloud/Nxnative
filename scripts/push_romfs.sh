#!/bin/bash
# Copy a game's files to its iPhone app's Documents/romfs.img once, so later installs built with DM_COPY_ROMFS=NO skip them (see docs/fork.md).
# The files go as one RomFS image (dm/tools/romfs_image.py), packed next to the RomFS folder on first use: one file copies at full speed, where a folder of a few hundred
# thousand files ran the phone's file service out of open files (Tears of the Kingdom: 304,000). main.m only takes a complete image, so a copy cut off halfway is never used.
# Usage: push_romfs.sh <device UDID> <bundle ID> <game>_build/xcode/Gen/resources.env
# Run it while the app (any build with that bundle ID) is installed. Rerun after a failure.
set -eu
dev=$1 id=$2; source "$3"
img=${DM_RESOURCE_ROMFS%/}.img
[ -f "$img" ] || python3 -I "$(dirname "$0")/../dm/tools/romfs_image.py" "$DM_RESOURCE_ROMFS" "$img"
for try in 1 2 3; do
    xcrun devicectl device copy to --device "$dev" --domain-type appDataContainer --domain-identifier "$id" --source "$img" --destination Documents/romfs.img -q && break
    [ $try = 3 ] && exit 1; sleep 10
done
echo "game files on the phone: $id"
