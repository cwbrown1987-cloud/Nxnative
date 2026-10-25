# Super Mario 3D All-Stars: Super Mario Sunshine (`010049900F546002`)

Base game 1.0.0 (v0, no update), SDK 9.5.1: program 2 of [Super Mario 3D All-Stars](../010049900F546000/README.md), started by its launcher with `oe::ExecuteProgram`. NERD's Hagi GameCube layer, as [Super Mario Galaxy](../010099C022B96000/README.md)'s Wii one: the PowerPC code is statically recompiled into an NRO (`data/gekko/MarioSunshine/nx/MarioSunshine.nrolz`, loaded with `ro::LoadModule`), and Hagi stands in for the GameCube: GX on **Vulkan** with SPIR-V generated at run time, the DSP by HLE, the memory card as `save:/MarioSunshine/A.sav`, DVD reads from `MarioSunshine/Super_Mario_Sunshine_Stardust-trimmed.gcm`. Modules `main`, `subsdk0` (NintendoSDK_movie, for the MP4 movies in `data/video_replace`) and `sdk`; `subsdk1` (NintendoSDK_OpenGL) and `subsdk2` (NintendoSDK_Vulkan) are replaced by the host's Vulkan layer. Plays on the Mac; in the collection's iPhone app, not yet run on a device.

On the Mac: the opening (the HD replacement movies; Plus skips it), the file select, a new file's opening in the plane and control at Delfino Airstrip, 30 fps; the pause menu with every item, and "Return to title selection" back to the launcher. Started without the launcher's launch parameter, the game quits at boot.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 6 GB layout: `mem_reserve 0x180000000`, `mem_alias 0x110000000`, `mem_stack 0x10000000`, `app_pool 0x50000000` | [`game.tsv`](game.tsv) | Hagi's two address regions in a 4.25 GB alias region, and a 1.25 GB heap region; 6 GB is the most iOS gives one reservation. See [Memory](#memory) |
| `sys_resource 0x800000` | `game.tsv` | the NPDM's 8 MB system resource: virtual address memory |
| Coroutine stack region cut 1 GB → 64 MB | [`patches.py`](patches.py), `main` build `ed0d7ace84ee…` | fits the 6 GB layout ([Memory](#memory)) |
| Node area cut 1 GB → 62 MB, 32 MB alignment of regions of 1 GB and more | `dm/tools/sdk_patches.py`, `sdk` build `cdb385c299fd…` (shared with [Super Mario 64](../010049900F546001/README.md)) | Hagi's 4 GB + 2 MB region did not fit after the node area, and its 1 GB alignment would lose up to 1 GB more |
| `op_mode handheld` | `game.tsv` | Hagi's preset (`hagi.config`): the pointer is the touch screen in handheld mode. Sunshine itself reads only the pad |
| `pad_layout full` | `game.tsv` | the 3D pad layout: the camera is on the right stick, the menus on the D-pad |
| `modules main subsdk0 sdk` | `game.tsv` | load order as on Horizon; the game NRO is mapped from `nro.tsv` when Hagi loads it |
| `zip_store .cache:.gcm:.har:.mp4:.nrolz:.png:.metallib` | `game.tsv` | stored as they are in the IPA |

The profile has no `vk_capture.tsv`, so the NSP script's capture stops once no module has been added for 20 s.

## Memory

- `main` sets a heap of pool − 64 MB. Hagi maps the GameCube's 32-bit address space 1:1 (`hagi.config` `Mmu false`) in one 4 GB + 2 MB address region (`main+0x125960`), then reserves its coroutine stacks as a second region of 1 GB (`main+0x14b02c` → `main+0x157940`). Without the `sdk` cuts the first failed and Hagi logged "Initialization of subsystem MEMORY failed" ([The SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area), [1 GB alignment of regions of 1 GB and more](../../../docs/reference/memory.md#1-gb-alignment-of-regions-of-1-gb-and-more)).
- The provisional profile's layout was 7.25 GB, over iOS's single 6 GB reservation. Hagi hands out its stacks with a bump allocator (`main+0x157a00`); measured through boot, the opening and Delfino Airstrip it gave out twelve 64 KB stacks and nineteen 64 KB blocks, under 2 MB, so `patches.py` cuts the region to 64 MB (`main+0x14b034`). Both regions then end at +4.16 GB of the alias region, and the block is 6 GB: 256 MB in front + alias 4.25 GB + stack 256 MB + heap region 1.25 GB. Measured on the Mac: the alias region touched up to +4.12 GB, the heap (1.19 GB) 450 MB.
- Footprint on the Mac 908–1,147 MB (the in-process switch cycles).

## Shaders

- Hagi generates its GX shaders as SPIR-V at run time from `data/database/pip/MarioSunshine/pipelineDB.pip`; the NSP script captures them on the Mac (1,152 modules) and `vk_shaders.py` translates the capture, as for Galaxy ([Vulkan shaders generated at run time](../../../docs/reference/rendering.md#vulkan-shaders-generated-at-run-time)).
- `romfs_marker` is `MarioSunshine/Super_Mario_Sunshine_Stardust-trimmed.gcm`.

## CPU

- **Resolved: Hagi's main thread at 88% of a core.** It polls a system event (`TryWaitSystemEvent`, `main+0x82c4`) and yields in turn, about 2.5 million times a second, and each poll ended the run of yields ([Zero-timeout polls between yields keep a yield run](../../../docs/reference/threads.md#zero-timeout-polls-between-yields-keep-a-yield-run)). The process went from 110% to about 50% of a core at Delfino Airstrip (main thread 870 → 290 ms/s), 30 fps held. With the Mac loaded (load average 15–23) frames had stretched to 100–400 ms and the sound crackled.

## Pause menu

- The pause menu is an offline web page (`launcher_pause_menu.htdocs` in the program's HtmlDocument NCA, 26 files, 0.8 MB, extracted to `html0/html-document/`). The game starts it hidden at boot (`BootMode` 1), waits in a `TryReceiveContentMessage` loop for the page's `end_sound_load`, `Appear`s it on Minus and sends "appear", and on `WaitForExit` compares the last URL with `http://localhost/return_to_launcher` (exit reason 2 is handled apart: `RequestExit`); `main+0x84f0` / `+0x86b0`.
- **Resolved: a null read in `applet::StartLibraryAppletImmediately` at boot**, from the SDK's `OfflineWebSession::Start`. The host shows the page in a web view ([Offline HTML pages in a web view](../../../docs/reference/services.md#offline-html-pages-in-a-web-view)): Minus shows the menu over the darkened game; Up / Down move through Continue, Controls, Actions (each guide with its picture) and Return to title selection; A on Continue, B, + and − resume; it opens again each time (the game starts a new page after each end). The menu's stylesheet names `../../img/` for `launcher_pause_menu.htdocs/img`, which the host looks up inside the document's folder.

## Game state

- The file select is not stuck: Mario starts between blocks A and B, and A makes him jump into the gap. Under a block, A opens START / COPY / ERASE; START plays the opening and gives control at Delfino Airstrip.
- The disc image holds the DOL's link map (`marioEU.MAP`), which names every PowerPC function, and Hagi's statifier table (`GetStatifierInfo` `GET_FUNCTION_INFO`: 12,781 records of PowerPC address and NRO offset) maps the recompiled code back to them.

## Mac input

- `DM_CTL` drives it: Minus for the pause menu, D-pad in the menus. A headless run has no web view (the stand-in page closes as it appears), so `program 0` is the way back there ([05, Scripted input](../../../docs/agents/05-debugging.md#scripted-input-and-thread-scheduling)).

## Found on this game

General host changes first needed here; each applies to every game:

- **Zero-timeout polls keep a yield run** (`thr_yield`): [Zero-timeout polls between yields keep a yield run](../../../docs/reference/threads.md#zero-timeout-polls-between-yields-keep-a-yield-run).
- **Offline HTML pages in a web view** (`hle_web.c`, `web_apple.m`, `nx_extract --html`, `DM_HTML`): [Offline HTML pages in a web view](../../../docs/reference/services.md#offline-html-pages-in-a-web-view).
- **Hagi's `.nrolz`** (the NRO's size big-endian, then one LZ4 block; `nro_collect.py`): [Loading NROs with `ro::LoadModule`](../../../docs/reference/services.md#loading-nros-with-roloadmodule).
- **The SDK 9.5.1 `sdk` build's node area and alignment cuts**: [The SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area).
- The Vulkan layer logs a timing line every 300 frames as the NVN layer does (present interval p50 / p95 / max, fps, process CPU, top yielders, guest thread CPU), and each present interval over 100 ms.

## Open

- Hagi crashed once in about 12 runs as the plane movie started (a trap at `main+0xe00d4` in its texture copy): its `VideoReplaceThread` stops the playing video replacement (`main+0xc00e4`) while the GPU thread may still be uploading that video's frame, whose pixels the upload's own path frees (`main+0xc169c`). A race inside Hagi; not cut.
- Not run on an iPhone: the game, and the pause page there (under the gamepad, touches on no control going to the page), which only compiles for the iPhone SDK so far. Not checked on the Mac: mouse clicks on the page and its sounds (`DM_AUDIO=1`).
