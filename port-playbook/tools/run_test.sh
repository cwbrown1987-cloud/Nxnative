#!/bin/bash
# usage: t.sh AUDIO(0/1)
APP="/Volumes/RAGHAV SSD/nintendo/PokemonLetsGoPikachu/Pokémon Let's Go Pikachu.app"
G="$APP/Contents/Resources/game"; DATA="$HOME/Library/Application Support/Pokemon Lets Go Pikachu"
export DM_WINDOW=1 DM_AUDIO=$1 DM_OPMODE=0 DM_ROOT="$DATA" DM_ROMFS="$G/RomFS" DM_SAVE="$DATA/save" DM_TEMP="$DATA/temp" DM_MSL_DIR="$G/shader/ios" DM_FONT_DIR="$G/font" DM_NVN_SHMAP="$G/profile/shader_map.tsv" DM_PSO_MANIFEST="$G/profile/pso_manifest.tsv" DM_PSO_USER="$DATA/pso_user.tsv"
exec "$APP/Contents/MacOS/dmhost" "$G/patched_v131072" >"$DATA/log.txt" 2>&1
