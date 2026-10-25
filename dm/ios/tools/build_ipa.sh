#!/bin/bash
# Build one unsigned all-in-one IPA: the rewritten modules compiled into the executable, iOS shader libraries at DmIOS.app/msl, and the game files (RomFS) at DmIOS.app/romfs.
# In IPA mode Xcode skips the large resource copy; tools/pack_ipa.py packs the shader libraries, add-on content and RomFS straight from where they are (no Payload/ copy, nothing through the home disk).
# In --prepare-xcode mode the generated project copies those resources before Xcode signs it with the team the user selects. This script never signs or installs anything.
# Prerequisites: the rewriter (patched directory) and the iOS shader build (IOSOUT) have been run as in the README; Xcode and xcodegen are installed.
# Usage: dm/ios/tools/build_ipa.sh [output.ipa | --prepare-xcode]; --prepare-xcode generates the project without building, signing or packing.
#   Environment: GAME=game profile (dm/games/<base game title ID>, or one in DM_GAMES_DIR; required), W=the game's work folder (required: <NSP folder>/<title ID>-work, never the home folder), PATCHED / ROMFS / MSL_IOS can each be overridden
#   AOC=add-on content directory (default $W/data/aoc; when it exists it goes to DmIOS.app/aoc/<index>/; an empty string = none), GFXAPI=nvn / vulkan (default: by the shader libraries in MSL_IOS)
#   The app name is the game name in the base NSP's control data ($W/data/v0/control.nacp, else the one next to the RomFS), the app version is the display version in the packed game's control data (the one next to the RomFS:
#   nx_extract saves the update's there when an update is packed, else the base game's), the bundle ID is org.nxnative.<base game title ID in lowercase> (DM_DISPLAY_NAME / DM_APP_VERSION / DM_BUNDLE_ID override them);
#   DM_SHOW_FPS=1 turns the frame-rate counter on (DMShowFPS in Info.plist; DM_SHOW_FPS in the app's Documents/env.txt overrides it on the phone);
#   DM_LANG=<language code> is the game language (DMLanguage in Info.plist, default en-US; DM_LANG in the app's Documents/env.txt overrides it on the phone);
#   both are also the launcher's defaults (dm/launcher.json from dm/games/settings.py; the player's choice there wins over them, Documents/env.txt over the choice);
#   the IPA name, code modules, RomFS marker and shader tables come from the game profile
#   PROGRAMS_TSV=<file> (the NSP script, a multi-program application: Super Mario 3D All-Stars): one app holding several programs, one row each, "<index>\t<profile>\t<patched>\t<RomFS>\t<iOS shaders>\t<graphics API>",
#   program 0's being GAME / PATCHED / ROMFS / MSL_IOS / GFXAPI (the app's name, version, icon and identity are its). Each program's modules go in sections tagged p<N> (gen_embed.py --tag),
#   its tables and launcher settings in dm/p<N>/, its RomFS and offline HTML pages in p<N>/, its shader libraries in msl/p<N>/, and the host is built over a table of their profiles
#   (game.py header-multi); main.m picks the program from the last oe::ExecuteProgram (Documents/program.bin). IPA only, not --prepare-xcode
set -u
cd "$(dirname "$0")/.." || exit 1
IOS_SOURCE=$PWD; IOS=$PWD; DM=$(cd .. && pwd)
t() { echo "[$(date +%T)] $*"; }; die() { t "FAIL: $*"; exit 1; }
[ -n "${GAME:-}" ] || die "GAME is not set: GAME=<base game title ID> $0; profiles: $(python3 "$DM/games/game.py" list | awk -F'\t' '{printf "%s (%s)  ", $1, $3}')"
export GAME; GD=$(python3 "$DM/games/game.py" dir "$GAME") || die "no game profile $GAME"   # dm/games/<id>, or a profile in DM_GAMES_DIR (the NSP script's provisional one); the make that gen_build.py runs uses the same GAME
gp() { python3 "$DM/games/game.py" "$GAME" "$1" || die "game profile $GD: $1"; }   # read a key of the game profile
[ -f "$GD/game.tsv" ] || die "no game profile $GD/game.tsv"
[ -n "${W:-}" ] || die "W is not set: W=<NSP folder>/$GAME-work (the game's work folder) $0"
PKG=$(gp package)
PATCHED=${PATCHED:-$W/build/patched_$PKG}; ROMFS=${ROMFS:-$W/data/$PKG/RomFS}; MSL_IOS=${MSL_IOS:-$W/build/ios/dmsh_b}; AOC=${AOC-$W/data/aoc}
PREPARE_XCODE=NO; [ "${1:-}" != --prepare-xcode ] || PREPARE_XCODE=YES
OUT_IPA=${1:-$(dirname "$W")/$(gp ipa)}; O=$W/build/ios/pkg; DD=$O/dd
XCODE_DD=${DM_XCODE_DERIVED_DATA:-$W/build/ios/xcode-dd}
MODS=$(gp modules); MARKER=$(gp romfs_marker)
NACP=$W/data/v0/control.nacp; [ -f "$NACP" ] || NACP=$(dirname "$ROMFS")/control.nacp
[ -n "${DM_DISPLAY_NAME:-}" ] || DM_DISPLAY_NAME=$(python3 "$DM/tools/nacp.py" "$NACP") || die "no game name in $NACP (re-extract with nx_extract, or set DM_DISPLAY_NAME)"
VNACP=$(dirname "$ROMFS")/control.nacp; [ -f "$VNACP" ] || VNACP=$W/data/v0/control.nacp
[ -n "${DM_APP_VERSION:-}" ] || DM_APP_VERSION=$(python3 "$DM/tools/nacp.py" --version "$VNACP") || { t "no display version in $VNACP: the app version is 1.0"; DM_APP_VERSION=1.0; }
export LC_ALL=C DM_BUNDLE_ID=${DM_BUNDLE_ID:-org.nxnative.$(echo "$GAME" | tr 'A-Z' 'a-z')} DM_DISPLAY_NAME DM_APP_VERSION DM_APP_CATEGORY=$(gp app_category) DM_TEAM_ID=${DM_TEAM_ID:-0000000000}   # placeholder identity: unsigned, the install tool replaces it
if [ "${DM_SHOW_FPS:-0}" = 1 ]; then export DM_SHOW_FPS=YES; else export DM_SHOW_FPS=NO; fi
export DM_LANG=${DM_LANG:-en-US}
if [ "$PREPARE_XCODE" = YES ]; then
  IOS=${DM_XCODE_PROJECT_DIR:-$W/xcode}
  mkdir -p "$IOS" || die "mkdir $IOS"
  IOS=$(cd "$IOS" && pwd)
  [ "$IOS" != "$IOS_SOURCE" ] || die "the per-game Xcode project must be outside dm/ios"
  # Source links follow repository edits; generated files and build products belong to this game only. Linked again each time: a project prepared from another checkout (a removed worktree) follows this one
  for item in Sources tools; do ln -sfn "$IOS_SOURCE/$item" "$IOS/$item" || die "link $item"; done
  cp "$IOS_SOURCE/project.yml" "$IOS/project.yml" || die "copy project template"
  cd "$IOS" || die "cd $IOS"
  DM_SCHEME_NAME="$(echo "$DM_DISPLAY_NAME" | tr '/:' '__') ($GAME)"   # the scheme file is named after it

else DM_SCHEME_NAME=DmIOS; fi
export DM_SCHEME_NAME
# The checks of one program's inputs (GAME, GD, PATCHED, ROMFS, MSL_IOS, GFXAPI, MODS, MARKER as set): every program of an app of several programs passes them
check_program() {
for f in $MODS; do [ -f "$PATCHED/$f.patched.bin" ] && [ -f "$PATCHED/$f.fixups.tsv" ] || die "no rewritten module $PATCHED/$f (run dm/tools/patch_nso.py first)"; done
[ -e "$ROMFS/$MARKER" ] || die "no RomFS at $ROMFS (missing $MARKER)"
V=${V:-$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$DM/gfx/nvn/dmsh_chain.h")}   # the chain version the host is compiled with, one for every game
# A Vulkan game (Hades): the shaders are the game's SPIR-V, translated by dm/gfx/tools/vk_shaders.py into $MSL_IOS/vk; an OpenGL game (Digimon Story Cyber Sleuth): its GLSL, translated by
# dm/gfx/tools/gl_shaders.py into $MSL_IOS/gl; neither has NVN chain libraries. GFXAPI=nvn / vulkan / gl says which (the NSP script passes what main imports); without it, the shader
# libraries in $MSL_IOS tell: the chain's b-$V, else vk, else gl
if [ -z "${GFXAPI:-}" ]; then if ls "$MSL_IOS/b-$V" 2> /dev/null | grep -q '_b.metallib$'; then GFXAPI=nvn; elif [ -f "$MSL_IOS/vk/vk_shaders.metallib" ]; then GFXAPI=vulkan;
  elif [ -f "$MSL_IOS/gl/gl_shaders.metallib" ]; then GFXAPI=gl; else GFXAPI=nvn; fi; fi
if [ "$GFXAPI" = vulkan ]; then [ -f "$MSL_IOS/vk/vk_shaders.metallib" ] || die "no iOS Vulkan shader library $MSL_IOS/vk (dm/gfx/tools/vk_shaders.py \"$ROMFS\" <Mac dir> --ios \"$MSL_IOS\")"
elif [ "$GFXAPI" = gl ]; then [ -f "$MSL_IOS/gl/gl_shaders.metallib" ] || die "no iOS GL shader library $MSL_IOS/gl (dm/gfx/tools/gl_shaders.py \"$ROMFS\" <main> <Mac dir> --ios \"$MSL_IOS\")"
else [ -n "$V" ] && ls "$MSL_IOS/b-$V" 2> /dev/null | grep -q '_b.metallib$' || die "no iOS shader libraries $MSL_IOS/b-$V (IOSOUT=$MSL_IOS dmsh_build.py ...)"
  # One chain version serves every game and every state of a profile's tables: the libraries' stamp (b-$V/inputs.tsv, written by a full dmsh_build.py run) must name this game and the
  # digest of its profile's current inputs, and c1_full.tsv (not in the repository: the same build makes it, and cb_extent.tsv, from its Mac outputs) must name that digest, or the host ignores it
  IN=$(DM_GAME="$GAME" python3 "$DM/gfx/tools/dmsh_chain.py" --inputs) || die "dmsh_chain.py --inputs (game profile $GD)"
  grep -qxF "$(printf 'game\t%s' "$GAME")" "$MSL_IOS/b-$V/inputs.tsv" 2> /dev/null && grep -qxF "$(printf 'inputs\t%s' "$IN")" "$MSL_IOS/b-$V/inputs.tsv" ||
    die "the iOS shader libraries $MSL_IOS/b-$V are not a full build from this profile's current tables (inputs $IN; their stamp: $([ -f "$MSL_IOS/b-$V/inputs.tsv" ] && grep -v '^#' "$MSL_IOS/b-$V/inputs.tsv" | tr '\n\t' '  ' || echo none)): build them again (IOSOUT=$MSL_IOS dmsh_build.py ...)"
  head -1 "$GD/c1_full.tsv" 2> /dev/null | grep -q "^# chain b-$V inputs $IN " || die "$GD/c1_full.tsv is missing or not made from these libraries (chain $V, inputs $IN): a full dmsh_build.py run makes it and cb_extent.tsv"; fi
}
check_program
[ -z "${PROGRAMS_TSV:-}" ] || [ "$PREPARE_XCODE" = NO ] || die "PROGRAMS_TSV (an app of several programs) packs an IPA only, not --prepare-xcode"
P0=$GAME; P0_PATCHED=$PATCHED; P0_ROMFS=$ROMFS; P0_MSL=$MSL_IOS; P0_GFX=$GFXAPI
prog_rows() { grep -v '^#' "$PROGRAMS_TSV" | grep -v '^$'; }   # index, profile, patched, RomFS, iOS shaders, graphics API
prog_set() {   # the globals of one row's program
  IFS=$'\t' read -r PN GAME PATCHED ROMFS MSL_IOS GFXAPI <<< "$1"; export GAME
  GD=$(python3 "$DM/games/game.py" dir "$GAME") || die "no game profile $GAME"; MODS=$(gp modules); MARKER=$(gp romfs_marker)
  if [ "$GFXAPI" = vulkan ]; then MSLDIR=vk; elif [ "$GFXAPI" = gl ]; then MSLDIR=gl; else MSLDIR=b-$V; fi
}
prog_back() { GAME=$P0; export GAME; GD=$(python3 "$DM/games/game.py" dir "$GAME"); PATCHED=$P0_PATCHED; ROMFS=$P0_ROMFS; MSL_IOS=$P0_MSL; GFXAPI=$P0_GFX; MODS=$(gp modules); MARKER=$(gp romfs_marker); }
if [ -n "${PROGRAMS_TSV:-}" ]; then
  [ -f "$PROGRAMS_TSV" ] || die "no PROGRAMS_TSV $PROGRAMS_TSV"
  while IFS= read -r row; do prog_set "$row"; t "program $PN: $GAME ($(gp name)), $GFXAPI"; check_program; done < <(prog_rows)
  prog_back
fi

t "app: $DM_DISPLAY_NAME $DM_APP_VERSION ($DM_BUNDLE_ID), language $DM_LANG$([ $DM_SHOW_FPS = YES ] && echo ', frame-rate counter on')"
t "generate Gen/ (host sources, embedded modules, tables)"
rm -rf Gen && mkdir -p Gen/dm || die "mkdir Gen"
python3 tools/gen_build.py "$DM/host" Gen > Gen/dm.xcconfig || die "gen_build"
if [ -n "${PROGRAMS_TSV:-}" ]; then   # the host over a table of the programs' profiles, found before gen/<GAME>/ (game.py header-multi); each program's modules under its tag
  python3 "$DM/games/game.py" header-multi Gen/profile/game_profile.h $(prog_rows | awk -F'\t' '{printf "%s=%s ", $1, $2}') || die "game.py header-multi"
  sed -i '' "s|^HEADER_SEARCH_PATHS = \$(inherited) |HEADER_SEARCH_PATHS = \$(inherited) \"$IOS/Gen/profile\" |" Gen/dm.xcconfig || die "header path"
  F=; : > Gen/embed.S
  while IFS= read -r row; do prog_set "$row"
    F="$F $(python3 tools/gen_embed.py --tag "p$PN" "$PATCHED" "Gen/embed_p$PN.S" $MODS)" || die "gen_embed (program $PN)"
    cat "Gen/embed_p$PN.S" >> Gen/embed.S && rm "Gen/embed_p$PN.S"
  done < <(prog_rows); prog_back
else F=$(python3 tools/gen_embed.py "$PATCHED" Gen/embed.S $MODS) || die "gen_embed"; fi
echo "OTHER_LDFLAGS = \$(inherited) \$(DM_FRAMEWORKS) $F" >> Gen/dm.xcconfig
# One program's tables into TD: the rewriter's, the shader tables and the launcher's settings
program_tables() {
cp "$PATCHED"/*.fixups.tsv "$PATCHED"/*.gates.tsv "$PATCHED"/*.cuts.tsv "$PATCHED"/*.obs.tsv $TD/ || die "copy rewriter tables"
if [ -f "$PATCHED/nro.tsv" ]; then cp "$PATCHED/nro.tsv" $TD/ || die "copy the NRO table"; fi   # the NRO modules the game loads with nn::ro (hle_ro.c), embedded by gen_embed.py
if [ "$GFXAPI" = vulkan ] || [ "$GFXAPI" = gl ]; then cp "$GD/shader_map.tsv" "$GD/pso_manifest.tsv" $TD/ || die "copy shader tables"   # empty NVN tables: the NVN layer draws nothing
else cp "$GD/shader_map.tsv" "$GD/pso_manifest.tsv" "$GD/c1_full.tsv" $TD/ || die "copy shader tables"
  if [ -f "$GD/cb_extent.tsv" ]; then cp "$GD/cb_extent.tsv" $TD/ || die "copy cb_extent.tsv"; else t "no $GD/cb_extent.tsv: the host copies whole uniform bindings"; fi; fi   # optional
# The launcher's settings for this game (Launcher.swift): dm/games/settings.tsv filtered by the profile, main's rewriter table and the game's languages (dm/games/settings.py)
L=$(GFXAPI="$GFXAPI" python3 "$DM/games/settings.py" "$GAME" "$PATCHED" "$VNACP" $TD/launcher.json) || die "launcher settings (dm/games/settings.py)"; t "launcher: $L"
}
if [ -n "${PROGRAMS_TSV:-}" ]; then
  : > Gen/dm/programs.txt
  while IFS= read -r row; do prog_set "$row"; TD=Gen/dm/p$PN; mkdir -p "$TD" || die "mkdir $TD"; VNACP=$(dirname "$ROMFS")/control.nacp; program_tables; echo "$PN" >> Gen/dm/programs.txt; done < <(prog_rows)
  prog_back; VNACP=$(dirname "$ROMFS")/control.nacp; [ -f "$VNACP" ] || VNACP=$W/data/v0/control.nacp
else TD=Gen/dm; program_tables; fi
# Diagnostic build: DM_ENV_FILE=file → dm/env.txt in the bundle (main.m sets one environment variable per line at boot)
if [ -n "${DM_ENV_FILE:-}" ]; then cp "$DM_ENV_FILE" Gen/dm/env.txt || die "copy DM_ENV_FILE"; t "env: $(grep -v '^#' "$DM_ENV_FILE" | tr '\n' ' ')"; fi
# The shader libraries go into the archive as DmIOS.app/msl/<folder> (main.m sets DM_MSL_DIR to it)
if [ "$GFXAPI" = vulkan ]; then MSLDIR=vk; elif [ "$GFXAPI" = gl ]; then MSLDIR=gl; else MSLDIR=b-$V; fi
# Shared-font stand-ins: standard = macOS's Arial Unicode (absent on iOS), Nintendo extension = button icons generated by make_ext_font.py (needs fontTools; FONT_PY names a python that has it)
mkdir -p Gen/dm/font && cp "${STD_FONT:-/System/Library/Fonts/Supplemental/Arial Unicode.ttf}" Gen/dm/font/standard.ttf || die "copy standard font (STD_FONT=a TTF)"
"${FONT_PY:-python3}" "$DM/tools/make_ext_font.py" Gen/dm/font/nintendo_ext.ttf > /dev/null || die "make_ext_font.py (pip install fonttools, or FONT_PY=python with fontTools)"
# App icon: the game's own icon (icon.jpg saved from the control data by nx_extract, the English 256x256 one). DM_ICON can point at another image; by default the icon.jpg next to the RomFS is used.
# It is scaled to a 1024x1024 PNG in the asset catalog Gen/Assets.xcassets (a single-size app icon; actool generates the other sizes); with neither, no icon is set and the home-screen icon is blank.
# The catalog is always created (the project always lists it, see project.yml); without an icon it stays empty and DM_APPICON is not set
ICON=${DM_ICON:-$(dirname "$ROMFS")/icon.jpg}
mkdir -p Gen/Assets.xcassets && printf '{"info":{"author":"xcode","version":1}}\n' > Gen/Assets.xcassets/Contents.json || die "asset catalog"
if [ -f "$ICON" ]; then
  AI=Gen/Assets.xcassets/AppIcon.appiconset; mkdir -p "$AI" || die "mkdir $AI"
  sips -s format png -z 1024 1024 "$ICON" --out "$AI/icon.png" > /dev/null || die "sips: cannot convert the icon $ICON"
  printf '{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}\n' > "$AI/Contents.json"
  echo "DM_APPICON = AppIcon" >> Gen/dm.xcconfig
  t "app icon: $ICON"
else t "no app icon ($ICON not found): the home-screen icon stays blank"; fi
# A prepared Xcode project is signed in Xcode, so it asks for the Increased Memory Limit capability the bigger games need (see the README); DM_ENTITLEMENTS=another plist, or empty for none.
# The unsigned IPA has none: the install tool adds it.
if [ "$PREPARE_XCODE" = YES ] && [ -n "${DM_ENTITLEMENTS-default}" ]; then
  if [ -n "${DM_ENTITLEMENTS:-}" ]; then cp "$DM_ENTITLEMENTS" Gen/DmIOS.entitlements || die "copy DM_ENTITLEMENTS"
  else printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict><key>com.apple.developer.kernel.increased-memory-limit</key><true/></dict></plist>' > Gen/DmIOS.entitlements || die "entitlements"; fi
  echo "CODE_SIGN_ENTITLEMENTS = Gen/DmIOS.entitlements" >> Gen/dm.xcconfig
  t "entitlements: $(plutil -convert json -o - Gen/DmIOS.entitlements)"
fi
xcodegen generate -q > /dev/null || die "xcodegen"
python3 tools/gen_resources.py "$IOS" "$ROMFS" "$MARKER" "$MSL_IOS/$MSLDIR" "$MSLDIR" "$AOC" "$XCODE_DD" "$DM/gfx/nvn/dmsh_chain.h" || die "generate Xcode resource paths"
if [ "$PREPARE_XCODE" = YES ]; then
  t "Xcode project: $IOS/DmIOS.xcodeproj"
  t "Xcode derived data: $XCODE_DD"
  t "scheme: $DM_SCHEME_NAME"
  t "ready: select your Team in Signing & Capabilities, select a physical device, and Run (Release)"
  exit 0
fi

t "xcodebuild (Release, unsigned, iPhone + iPad)"
mkdir -p "$O"
xcodebuild -project DmIOS.xcodeproj -scheme DmIOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DM_COPY_GAME_RESOURCES=NO \
  DM_XCODE_OUTPUT_ROOT="$DD" SYMROOT="$DD/Build/Products" OBJROOT="$DD/Build/Intermediates.noindex" build > "$O/build.log" 2>&1 \
  || { grep -E 'error:' "$O/build.log" | head -20; die "xcodebuild, log $O/build.log"; }
# SYMROOT and OBJROOT above keep the unsigned build separate from the interactive Xcode app.
APP=$DD/Build/Products/Release-iphoneos/DmIOS.app
[ -n "$APP" ] && [ -d "$APP" ] || die "no built app"; t "app: $APP"

# Straight from the sources: the app without its signature, and without the folders an app built before pack_ipa.py still has (DerivedData keeps resources that left the project;
# msl/ is also deleted there, it took 1.5 GB of the home disk), then the shader libraries, the add-on content (the RomFS extracted from the player's DLC NSPs, one folder per index:
# the app sets DM_AOC_DIR at launch, the host reports them as owned and mounts them from it) and the RomFS
rm -rf "$APP/msl" "$O/Payload" "$O/out.ipa"   # (the last two: what the copy-and-zip packing left behind)
P=Payload/DmIOS.app; SKIP=(--skip $P/_CodeSignature --skip $P/embedded.mobileprovision --skip $P/msl --skip $P/aoc --skip $P/romfs --skip $P/html)
if [ -n "$AOC" ] && [ -d "$AOC" ]; then MAPS_AOC=("$P/aoc=$AOC"); t "add-on content: $(ls "$AOC" | tr '\n' ' ')"; else MAPS_AOC=(); fi
if [ -n "${PROGRAMS_TSV:-}" ]; then   # each program's shader libraries, RomFS and offline HTML pages under its own folder
  MAPS=("$P=$APP" "${MAPS_AOC[@]}")
  while IFS= read -r row; do prog_set "$row"; SKIP+=(--skip "$P/p$PN")
    MAPS+=("$P/msl/p$PN/$MSLDIR=$MSL_IOS/$MSLDIR" "$P/p$PN/romfs=$ROMFS")
    if [ -d "$(dirname "$ROMFS")/html" ]; then MAPS+=("$P/p$PN/html=$(dirname "$ROMFS")/html"); fi
  done < <(prog_rows); prog_back
else
  MAPS=("$P=$APP" "$P/msl/$MSLDIR=$MSL_IOS/$MSLDIR" "${MAPS_AOC[@]}" "$P/romfs=$ROMFS")
  if [ -d "$(dirname "$ROMFS")/html" ]; then MAPS+=("$P/html=$(dirname "$ROMFS")/html"); t "offline HTML pages: $(dirname "$ROMFS")/html"; fi   # beside romfs, where the host finds them (hle_web.c)
fi
t "pack IPA (already-compressed game files stored, everything else deflated)"
ZS=$(gp zip_store); [ -z "${PROGRAMS_TSV:-}" ] || ZS=$(for g in $(prog_rows | cut -f2); do python3 "$DM/games/game.py" "$g" zip_store; done | tr ':' '\n' | sort -u | paste -sd: -)   # every program's
python3 tools/pack_ipa.py "$OUT_IPA" --store "$ZS" "${SKIP[@]}" "${MAPS[@]}" || die "pack_ipa"
t "done: $OUT_IPA ($(du -h "$OUT_IPA" | cut -f1))"
