#!/bin/bash
# Xcode target phase: copy the active game's resources into the app before CodeSign.
# Paths come from build_ipa.sh, not from a per-game rule or a phone-visible Mac path.
set -eu
[ "${DM_COPY_GAME_RESOURCES:-YES}" != NO ] || exit 0
die() { echo "[RED] $*" >&2; exit 1; }
[ "${PLATFORM_NAME:-}" = iphoneos ] || die 'This game needs a physical iPhone or iPad; choose a device, not a simulator.'
[ -f "${SRCROOT:?}/Gen/resources.env" ] || die 'Missing game resource paths; run build_ipa_from_nsp.py --prepare-xcode first.'
source "$SRCROOT/Gen/resources.env"
APP="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
case "$APP" in /*.app) ;; *) die "Unexpected app resource destination: $APP";; esac
# Validate every source before copying or removing anything (the external drive may be disconnected).
check_program() {   # RomFS, marker, shader libraries, shader folder
    [ -e "$1/$2" ] || die "Game files unavailable: $1/$2"
    [ -d "$3" ] || die "Shader libraries unavailable: $3"
    # The host is compiled from the repository's current sources and loads only msl/b-<its chain version>: after a chain change (a pull, dmsh_chain.py --header) the prepared shaders are another chain's
    case "$4" in b-*)
        [ -f "$DM_RESOURCE_CHAIN_H" ] || die "No chain version header: $DM_RESOURCE_CHAIN_H (a project prepared before the chain version moved to dm/gfx/nvn: prepare the game again, build_ipa_from_nsp.py --prepare-xcode)"
        V=$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$DM_RESOURCE_CHAIN_H")
        [ "$4" = "b-$V" ] || die "The prepared shaders are chain $4, the sources are now at b-$V: prepare the game again (build_ipa_from_nsp.py --prepare-xcode)";;
    esac
}
# The folders beside a RomFS (nx_extract --html, the NSP script's nn::jit image) into the app folder given, where the host finds them beside its romfs (hle_web.c, loader.c dm_jit_serve_dir)
beside_romfs() {
    for d in html jit; do
        if [ -d "$(dirname "$1")/$d" ]; then mkdir -p "$2/$d"; /usr/bin/rsync -a --delete -- "$(dirname "$1")/$d/" "$2/$d/"; else rm -rf "${2:?}/$d"; fi
    done
}
DM_RESOURCE_PROGRAMS=${DM_RESOURCE_PROGRAMS:-}
prog_rows() { grep -v '^#' "$DM_RESOURCE_PROGRAMS" | grep -v '^$'; }   # index, RomFS, marker, shader libraries, shader folder
if [ -n "$DM_RESOURCE_PROGRAMS" ]; then
    [ -f "$DM_RESOURCE_PROGRAMS" ] || die "Missing the programs' resource table $DM_RESOURCE_PROGRAMS; run build_ipa_from_nsp.py --prepare-xcode again."
    while IFS=$'\t' read -r pn romfs marker shaders msldir; do check_program "$romfs" "$marker" "$shaders" "$msldir"; done < <(prog_rows)
else check_program "$DM_RESOURCE_ROMFS" "$DM_RESOURCE_MARKER" "$DM_RESOURCE_SHADERS" "$DM_RESOURCE_MSLDIR"; fi
[ -z "$DM_RESOURCE_AOC" ] || [ -d "$DM_RESOURCE_AOC" ] || die "Add-on content unavailable: $DM_RESOURCE_AOC"
echo 'Copy game resources (the first build copies the complete game; later builds sync changes)'
if [ -n "$DM_RESOURCE_PROGRAMS" ]; then
    # An app of several programs (build_ipa.sh PROGRAMS_TSV): each program's RomFS, offline pages and nn::jit image in p<index>/, its shader libraries in msl/p<index>/, as the IPA has them (main.m)
    rm -rf "$APP/romfs" "$APP/html" "$APP/jit"   # one program's folders, from a project prepared for one program
    keep=' '
    while IFS=$'\t' read -r pn romfs marker shaders msldir; do
        mkdir -p "$APP/p$pn/romfs" "$APP/msl/p$pn/$msldir"
        /usr/bin/rsync -a --delete -- "$romfs/" "$APP/p$pn/romfs/"
        /usr/bin/rsync -a --delete -- "$shaders/" "$APP/msl/p$pn/$msldir/"
        for old in "$APP/msl/p$pn/"*; do [ "$old" = "$APP/msl/p$pn/$msldir" ] || rm -rf "$old"; done
        beside_romfs "$romfs" "$APP/p$pn"
        keep="$keep p$pn "
    done < <(prog_rows)
    for old in "$APP"/p[0-9]* "$APP/msl/"*; do [ -e "$old" ] || continue; case "$keep" in *" $(basename "$old") "*) ;; *) rm -rf "$old";; esac; done
else
    mkdir -p "$APP/romfs" "$APP/msl/$DM_RESOURCE_MSLDIR"
    /usr/bin/rsync -a --delete -- "$DM_RESOURCE_ROMFS/" "$APP/romfs/"
    /usr/bin/rsync -a --delete -- "$DM_RESOURCE_SHADERS/" "$APP/msl/$DM_RESOURCE_MSLDIR/"
    for old in "$APP/msl/"*; do
        [ "$old" = "$APP/msl/$DM_RESOURCE_MSLDIR" ] || rm -rf "$old"
    done
    beside_romfs "$DM_RESOURCE_ROMFS" "$APP"
    for old in "$APP"/p[0-9]*; do [ -d "$old" ] && rm -rf "$old"; done   # the programs of a project prepared for several
fi
if [ -n "$DM_RESOURCE_AOC" ]; then
    mkdir -p "$APP/aoc"
    /usr/bin/rsync -a --delete -- "$DM_RESOURCE_AOC/" "$APP/aoc/"
else
    rm -rf "$APP/aoc"
fi
