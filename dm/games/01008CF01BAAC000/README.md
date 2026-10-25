# The Legend of Zelda: Echoes of Wisdom (`01008CF01BAAC000`)

Base game 1.0.0 (`v0`, a cartridge dump, no update), SDK 16.2.0 (Mario Wonder's). Grezzo's engine on NintendoWare (G3d / Ui2d / Vfx / Atk / Font), as Link's Awakening, on **NVN**. Modules main + subsdk0 (GLSLC, which `main` imports `glslcCompilePreSpec` from) + subsdk1 (movie) + sdk. Its movies are WebM files in `region_common/movie`, played through the SDK's movie library.

**Current:** plays on the iPad (IPA 8.4 GB) from the base game 1.0.0 (`v0`), no update. On the Mac: the boot, the title (Press Any Button), file select and about 4 minutes of play, at 60 fps with stretches where the game itself runs at 30 (33.3 ms frames), with sound; about 1.5 GB resident and flat while it runs. The only red lines are Core Haptics' on the Mac (no rumble motor) and one `texture type mismatch: shader declares a cube, texture is 2D (texture ID 271)`, for which the zero cube is bound (what that texture is was not looked into).

## What it needs

| Setting | Where | Why |
|---|---|---|
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | 256 MB in front + 256 MB alias region + 256 MB stack region + 3.25 GB heap region; the game sets a 3.11 GB heap |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares no system resource: no virtual address memory, as on Horizon |
| `mem_used 0x6600000` | `game.tsv` | the rewritten modules exceed the default 64 MB of used memory |
| `modules main subsdk0 subsdk1 sdk` | `game.tsv` | every module `main` imports from: `subsdk0` is GLSLC (`glslcCompilePreSpec`), `subsdk1` the movie library |
| `shader_groups`, `shader_note` | `game.tsv` | the provisional profile's, kept: they are in every shader's cache key |

The provisional profile the NSP script guessed booted and played the game as it is: the registered profile adds only the app's name and category.

## Files and shaders

- 10,963 RomFS files (7.48 GB), nearly all under `region_common/` (maps 2.78 GB, actors 1.19 GB, audio 1.29 GB, shared textures 0.99 GB), with the text of each language under `region<XX>/`.
- 9,799 BNSH programs (5,234 vertex, 4,528 pixel, 37 compute): the particle effects in `region_common/effect/*.ptcl` (5,944), the `.bfsha` archives in `region_common/shader` (3,576), the layouts' `bgsh` in `region_common/ui/*.arc` and 40 in `main`.
- **Cartridge dump:** the base game is an XCI with no ticket and no tags in its file name, so the NSP script could not tell its title ID or version; renamed with `[01008CF01BAAC000][v0]`, it is packed as any other.

## Rendering and stutter

- The first use of a Metal pipeline takes 40–450 ms; the prewarm list (576 lines, recorded on the Mac over the route above) removes most of it on later runs (29 long frames → 5). A few presents on the Mac stall 100–300 ms in the display link and come and go between runs (`DM_PRESENT_LINK=0` against `1`, two pairs of runs: inconclusive).

## Mac routes

- Input: the pad only (`main` imports no touch screen); the default 2D gamepad layout.
- The work folder's `run.sh <log> [secs] VAR=…` boots the Mac host from the NSP script's build folder, its log in `logs/`.

## Open

- No update was brought up; only the base game 1.0.0 is registered.
- The cube-for-2D texture mismatch (texture ID 271, the zero cube bound) was not looked into.
