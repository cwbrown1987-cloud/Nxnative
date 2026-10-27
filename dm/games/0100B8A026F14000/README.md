# FINAL FANTASY RESONANCE (Korean release) (`0100B8A026F14000`)

Update 1.0.1 (v65536) over the base game, SDK 20.5.17, NVN, CRIWARE sound and movies. Square Enix's Unreal Engine 5.6.1 (the desktop renderer, `SF_GLSL_SWITCH` shaders). Modules `main`, `subsdk0` (the movie module, which `main` imports from) and `sdk`; `sdk` and `subsdk0` are the builds the Japanese release runs ([0100606026F12000](../0100606026F12000/README.md)).

**Status:** brought up on the Mac: the title, a new game (Normal difficulty), the opening cutscene, the first field, and Continue from a save, at 60 fps with no red line apart from one `texture type mismatch` (the Japanese release's note has the same one). Not yet tested on an iPhone.

**This is the Korean release of the same game: the same code as the Japanese one, with the Korean resources.** The build ID differs (`main` `b7f965b9d7227db8e29f04e84ea7331b` against `84e182f72ee1da4f477804bd05b54c15`) but **every address is the same** — the FMallocBinned3 constructor call (`main+0x137f0`), its object (`main+0x77c6210`), its vtable (`main+0x67df800`) and `rhi.SyncInterval`'s object (`main+0x8adca10`) all match. Everything the Japanese release's profile says holds here; only the build ID and the language (`ko`) differ. The two releases share one `subsdk0` and one `sdk` build.

What the profile needs, and what was found on it, is the Japanese release's note (the mechanisms are the same ones, and this release confirms them on a second build): the Unreal allocator in the host, the IoStore shader libraries, the node area cut, 60 fps. This note lists what is specific to this release.

## What it needs

| Setting | Where | Why |
|---|---|---|
| FMallocBinned3 constructor cut: `main+0x137f0` `bl 0xae770` → `nop` | [`patches.py`](patches.py) | the constructor reserves 38 GB of address space for its pools (`main+0xae82c`: the size `0x980000000` is hardcoded in the game and does not follow `-SwitchVirtualAddressSpaceSize=`, so that switch cannot help). The host puts its allocator's vtable in the object (hle_uemalloc.c, layout `UE5_6`: 32 slots, the vtable at `main+0x67df800` has 32) |
| `game_args -SwitchVirtualAddressSpaceSize=4064` | [`game.tsv`](game.tsv) | the engine's own page allocator never gives address space back: a 2 GB region aborted in the first battle. This SDK build aligns regions of 2 MB and more to 2 MB only, so the region starts right after the node area |
| Engage's 5 GB block: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | 256 MB in front + 4.375 GB alias region + 256 MB stack region + 128 MB heap region |
| `sys_resource 0x1400000` | [`game.tsv`](game.tsv) | the NPDM declares 20 MB of system resource |
| `tex_dyn_slots on` | [`game.tsv`](game.tsv) | 2,077 particle vertex shaders pick their texture slot at run time |
| `fps_target 60` | [`game.tsv`](game.tsv), `hle_fpslock.c` | the engine's Switch device profile sets `rhi.syncinterval=2`, so the game asks for present interval 2; the host writes `rhi.SyncInterval` 1 whenever the game sets it back (at level loads) |
| `pad_layout full` | [`game.tsv`](game.tsv) | a 3D field whose camera the right stick tilts and turns |
| `language ko` | [`game.tsv`](game.tsv) | the card is the Korean release: the game has `ko`, `zh-Hant` and `zh-Hans` |

The node area cut (1 GB → 62 MB) is the SDK build's own patch (`dm/tools/sdk_patches.py`, the same `sdk` build the Japanese release runs), so nothing game-specific is needed for it.

## Measured on the Mac

- The host runs Unreal's heap on a malloc zone (the FMallocBinned3 object at `main+0x77c6210`), the guest's address space reservation drops from 68 GB to 28 GB (`guest AS 0x7000000000`), and the Unreal heap grows on the host's allocator.
- 60 fps (59.7–59.8), the frame time p50 at 16.7 ms.
- The shader table holds all **73,496** shaders of the game (9,253 vertex, 61,305 pixel, 2,934 compute, 4 geometry) — the two IoStore shader library chunks of `FFRS-Switch.utoc` (type 8) with their 5,919 shader groups (type 9), read through the game's own Oodle in the host's tool mode (`uepak.py` `Toc` / `io_archive` / `OodleHost`, `DM_OODLE_SERVE`, served before the SDK starts, no boot).
- The title screen, the new game's difficulty menu (the text in Chinese), the opening cutscene and the first field render completely: the HD-2D sprites, the 3D scene, the minimap and the UI all correct, the four Eldrake crystals on the title screen included. No red line apart from one `texture type mismatch` (the `VolumetricLightmapStreaming` compute, which the Japanese release's note has as well).

## How to reach a scene on the Mac

From a fresh save, the title screen's `New Game`, the difficulty `Normal` and the tutorial's `Yes` lead to the opening and the first field; the field's `Continue` resumes from the save. The keyboard is the Nintendo layout (`J`=A, `K`=B, `U`=X, `I`=Y, `Q`=L, `E`=R, `Z`=ZL, `C`=ZR, the arrow keys are the D-pad, `WASD` the left stick), the same as the Japanese release's.

## The iPhone

The Japanese release plays on an iPhone, with the same memory layout this one now has (`-SwitchVirtualAddressSpaceSize=4064`, a 5 GB block, the node area cut to 62 MB, Unreal's heap on the host's), so this release should go there as well. Two earlier objections to the iPhone are gone with the old 68 GB layout:

- The guest's reservation is now 28 GB, which fits the address space the `com.apple.developer.kernel.extended-virtual-addressing` entitlement gives (about 64 GB); the old layout wanted 68 GB and did not.
- The host's alias region is 4.375 GB, not 64 GB, so the single reservation the host makes for the guest fits.

What is missing is the iOS shader library (the same MSL compiled with the iPhoneos convention, `dmsh_build.py` with `IOSOUT=`) and the Xcode package; the user sideloads and signs it. The one thing left to watch is the device's memory: the Mac build holds 1.2-1.5 GB of Metal allocations, which an iPhone shares with the system.

## Open

- **The Eldrake in a battle is drawn at the top right of the screen**, on the window's edge. (The Japanese release's own gallery picture, taken on the Mac, shows the same battle working: the three enemy machines drawn in the field, the Eldrake standing on the ground at the right, the turn order bar and the HP/MP panel. The game is fine on the Mac; the difference is on this release's side.) It is **not** a missing shader: the shaders of the battle are all in the table and in the library (the 517 that the runtime dumps gave, which cover the first battle, are in the table and compiled), and the crystals of the title screen draw correctly. Two candidates are left: the position or the transform of the HD-2D sprite layer on the host, and the Korean release's own assets (this release differs from the Japanese one only in its resources). The Japanese release's picture weighs the second one: its battle is 2D pixel sprites (the enemy machines and the player alike) over a 3D field, so a sprite's place comes from the game's own data, and the host only draws it. A sprite at the screen's edge is therefore likelier to be this release's data than a host-side transform, but the pass dump can tell the two apart: the sprite is drawn in whichever pass the game draws the battle's sprites in. The host's `DM_CTL` control channel (`shot`, `passdump`, `key` in `dm/host/hle_hid.c`) can dump the render passes of the frame the Eldrake is in, which says which pass draws it.
- **The shaders that do not build are not the same ones as on the Japanese release.** Here the four geometry shaders build (`VolumetricFogVoxelization.usf:VoxelizeGS` twice, `TranslucentLightingShaders.usf:WriteToSliceMainGS`, `CopyShadowMaps.usf:CopyCubeDepthGS`); what fails is `GlobalDistanceFieldCompositeObjects.usf:CompositeObjectsIntoPagesCS` (twice): `array subscript is not an integer`. The reason is the source language: Unreal's `GLSL_SWITCH` lets a shader index an array with a value it computes at run time (the Switch's GPU does), while Metal takes only a compile-time constant index, and the translation writes the computed index straight into the subscript. It is the distance field's composite pass, which a close-quarters field does not use (the game asks for no missing shader). The Japanese release's note lists 3 geometry and 8 compute with 3D image atomics instead. The host folds a slice-writing geometry shader into the vertex shader's layer entry points (`prog_fold_gs` in `nvn_mtl.m`), so a geometry shader that builds is not used as one.
- Every control section of this game is 0x880 bytes (all 74,244 of them), so the host's fixed 0x880 hash length and the split's own length agree; the control section of a shorter one would make the two keys differ (the Japanese release's note and the port knowledge base's finding on Triangle Strategy).
