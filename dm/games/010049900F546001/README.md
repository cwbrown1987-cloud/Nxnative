# Super Mario 3D All-Stars: Super Mario 64 (`010049900F546001`)

Base game 1.0.0 (v0, no update), SDK 9.5.1: program 1 of [Super Mario 3D All-Stars](../010049900F546000/README.md), started by its launcher with `oe::ExecuteProgram`. An N64 emulator ("EmuAppNX64") running the Japanese Shindou ROM (`rom/Stardust_JP/01_UNSMJ3.002.bin`), with English text and fonts patched in at fixed N64 addresses by Lua scripts (`06_UNSMJ3.002.lua`). The N64 code runs three ways: C++-recompiled in an NRO (`05_UNSMJ3.002.nro`, the same file as `nro/NROBuilder.nro`, loaded with `ro::LoadModule`); the precompiled block list `03_UNSMJ3.002.pcb` (4,235 MIPS blocks, overlays included), which its JIT plugin (`nro/EmuSystemJITPlugin.nro`) turns into 14.2 MB of AArch64 at boot through `nn::jit`; and the blocks neither covers, compiled at run time. Renders with **Vulkan** (4 SPIR-V shaders in the RomFS). Modules `main` and `sdk`. Plays on the Mac, and in the collection's app on the owner's iPad Pro 11-inch (3rd generation), iPadOS 26.2 (the owner).

On the Mac: the Nintendo logo, the title's Mario head with PRESS +, the file select, a new file through Peach's letter and Lakitu's introduction to the castle grounds and the castle lobby, at 30 fps; the owner played into a course. From the launcher and back: Minus opens its pause menu (an offline page, `game=64`), "Return to title selection" and Yes end the page at `http://localhost/return_to_launcher`, and the game saves, unloads its NRO, tears its Vulkan state down and calls `ExecuteProgram(0)`.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `jit_key_data 4:0-7,24-27` | [`game.tsv`](game.tsv) | command 4's request is `{u32 pc, u32 1, u64 words, u64 offset, u32 count}` and 4 bytes of padding the game leaves uninitialised (`main+0x52470`): only the pc, the flag and the count make a request. See [nn::jit](#nnjit) |
| `jit_out_code 4:entries=4,count=0x20004,size=0x20000` | `game.tsv` | command 4's output lists the u32 offsets of the block's entry points 1 … count − 1 at +4, the count at +0x20004, the code size at +0x20000; the game computes the entries from the address it asked for (`main+0x5256c`) and advances that address by the size (`main+0x52640`) |
| 3.5 GB block: `mem_reserve 0xe0000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | the hardware's pool; a smaller heap breaks the boot. See [Memory](#memory) |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares no system resource: no virtual address memory |
| `pad_layout full` | `game.tsv` | the 3D pad layout: the camera is on the right stick |
| `modules main sdk` | `game.tsv` | `subsdk0` (NintendoSDK_Vulkan), `subsdk1` (NintendoSDK_OpenGL) and `subsdk2` (GLSLC) are not loaded; the precompiled NRO and the JIT plugin come from `nro.tsv` (collected by the hashes the RomFS's NRRs register) |
| Node area cut and 32 MB alignment of regions of 1 GB and more | `dm/tools/sdk_patches.py`, `sdk` build `cdb385c299fd…` | needed by Sunshine, whose `sdk` build this is too; the cuts apply to every module of that build ([Sunshine, Memory](../010049900F546002/README.md#memory)) |
| `zip_store .cpio:.nro:.pcb:.metallib` | `game.tsv` | stored as they are in the IPA |

## Memory

- `main` sets a heap of the pool − 64 MB − its 520 MB bss (counted as used memory): 2.64 GB. `nnMain` (`main+0x2984`) cuts it into expanded heaps of 390 MB (the JIT work buffer: 384 MB of code memory, 2 MB of data memory, 2 MB of plugin state), 128, 416, 128 and 400 MB and one of heap − 2,378 MB, and memsets each as it makes it: the whole heap is touched at boot (footprint 3.2 GB on the Mac; 3,188–3,330 MB in the in-process switch cycles).
- With a 1 GB heap the last heap's size went negative and the boot crashed (`main+0x2aac`), so the pool is the hardware's. The guest block is 3.5 GB (256 MB in front + 256 MB alias + 256 MB stack + 2.75 GB heap region), within iOS's 6 GB reservation; on the iPhone the JIT layout is a second reservation of 0.96 GB ([nn::jit](#nnjit)). The app has the increased memory limit.

## nn::jit

- **Resolved: `nn::jit::Initialize` crashed reaching for the jit service (`sdk+0x2e5414`).** The host takes the API over ([`nn::jit` taken over by the host](../../../docs/reference/services.md#nnjit-taken-over-by-the-host)). The game passes `rom:/.nrr/EmuAppNX64.nrr` and `rom:/nro/EmuSystemJITPlugin.nro` to `CreateJitEnvironment`.
- At boot: `Control(0)` with its 0xeb0-byte VM state, `GenerateCode` commands 1 and 2 (44 and 56 bytes of entry stubs), then command 3 with a 140 MB input and 0x108b (4,235) blocks: the precompiled block list becomes 14.2 MB of code in 27 ms, the same in every run. A capstone census of that code (3.55 million instructions) found no x18, SVC, system register, `adr` / `adrp` or literal load, and every direct branch inside the code memory, so nothing in it needs the rewriter. It does build absolute addresses with `movz` / `movk` (693,098 into `main`'s data, 8,431 into the precompiled NRO, 39 into `sdk`), so the code depends on where the modules are mapped.
- At run time command 4 compiles a handful of blocks: 5 in the owner's session into a course, 3 to 8 in other runs, 20–28 KB. The set repeats but is not fixed: the Lua patch sites (`0x802bbb5c` / `70` / `80`) at every boot, the file select's two overlay blocks (`0x80172de0`, `0x80173cd0`) when it opens, and `0x802727f4`, `0x80272954`, `0x80272ab0` in some boots only (timing).
- **The iPhone serves the code from an image** built on the Mac ([`nn::jit` served from an image on iOS](../../../docs/reference/services.md#nnjit-served-from-an-image-on-ios)). From 2 boot captures, 4 more boots and one play capture: 11 requests from 4 runs, 392,280 address sequences, 20,581 output relocations (command 3's pointers to its blocks), the requests seen in several runs identical after relocation. Served so on the Mac (`DM_JIT_SERVE`), the game ran from the title through the file select and a new file's introduction to the castle grounds with every request served (7 command 4 blocks at other offsets than asked) and no plugin.
- In the IPA: the image in the executable (`__TEXT,__dmp1_jit`, 14.2 MB), its index and outputs in `p1/jit`. The NSP script's JIT capture took 2:01 (two boots of about 20 s and the play capture). On the iPhone the JIT layout holds the code memory (384 MB, 13.6 MB of it the image) and the modules, which are mapped there instead of on their own.

## Vulkan

Each addition is general (any Vulkan game):

- **Resolved: a call through a null pointer right after the Vulkan instance (`main+0x7494`)**: [`VK_EXT_debug_report`](../../../docs/reference/rendering.md#vk_ext_debug_report).
- **Resolved: the pipeline refused by Metal** ("cannot be used to build a pipeline state"): it specializes one int of `shader_vulkan_frag.spv` ([Specialization constants as Metal function constants](../../../docs/reference/rendering.md#specialization-constants-as-metal-function-constants)).
- **Resolved: crashes on the null handle of an image the layer refused** (`vkGetImageMemoryRequirements`, `vkGetImageSubresourceLayout`): the N64's RGBA 5551 textures as `A1R5G5B5_UNORM_PACK16` and its IA 4-bit textures as `R4G4_UNORM_PACK8`, linear images the CPU writes ([Packed 16-bit formats and R4G4](../../../docs/reference/rendering.md#packed-16-bit-formats-and-r4g4)).
- **Resolved: the title's Mario head, the logo, the file select's frame and buttons missing, and choosing a file showing nothing** (the owner's report). The game clears its colour and depth-stencil targets with `vkCmdClearColorImage` / `vkCmdClearDepthStencilImage` every frame and sets its stencil state dynamically, all stubs then ([Image clears and dynamic stencil state](../../../docs/reference/rendering.md#image-clears-and-dynamic-stencil-state)).
- **Resolved: a crash in `set_free` from `vkFreeDescriptorSets` on the way back to the launcher**: it frees descriptor sets whose pool it already reset or destroyed ([Frees of descriptor sets whose pool is gone](../../../docs/reference/rendering.md#frees-of-descriptor-sets-whose-pool-is-gone)).
- **Resolved: with `DM_PROGRAM_SWITCH=inproc`, a crash in the launcher seconds after "Return to title selection"** (`_xzm_xzone_malloc_freelist_outlined`, malloc's free list corrupted; seen by the owner, and in every scripted run of that path), or in `objc_release` from `dm_vk_end_run`: its renderer teardown (`main+0x9500`) destroys the swap chain's images with `vkDestroyImage` and keeps the swap chain ([Swap chain images destroyed by the game](../../../docs/reference/rendering.md#swap-chain-images-destroyed-by-the-game)). The 40 switches of the headless cycles ended the game from `DM_CTL` and never ran that code. Since: 3 scripted runs launcher → Super Mario 64 → menu → launcher in a window with sound, the launcher alive 25 s after, no thread needing the fence.

## Mac routes

- The work folder's `010049900F546001-work/run.sh <log> <secs> [VAR=…]` runs the game alone; `ctl.sh` / `shotwait.sh` drive a run started with `DM_CTL`; `play_route.sh` plays from the title through a new file to the castle grounds (Plus at the head screen, A on file A, A through the text). B jumps, Y attacks, A closes text.
- `DM_JIT_SERVE=<dir>` runs it from a built image as the iPhone does; `DM_JIT_LOG=1` logs every `GenerateCode` request.

## Found on this game

General host changes first needed here; each applies to every game:

- **`nn::jit`** (`hle_jit.c`, `loader.c` `nro_load_alone`): [`nn::jit` taken over by the host](../../../docs/reference/services.md#nnjit-taken-over-by-the-host).
- **The JIT image for iOS** (`DM_JIT_CAPTURE`, `dm/tools/jit_capture.py`, `DM_JIT_SERVE`, the profile keys `jit_key_data` / `jit_out_code`, the NSP script's JIT capture): [`nn::jit` served from an image on iOS](../../../docs/reference/services.md#nnjit-served-from-an-image-on-ios), [dm/games/README.md, Keys](../README.md#keys).
- **Vulkan layer additions** (`VK_EXT_debug_report`, specialization constants, packed 16-bit and R4G4 formats, image clears, dynamic stencil state, stale descriptor-set frees, swap chain images the game destroys): [`VK_EXT_debug_report`](../../../docs/reference/rendering.md#vk_ext_debug_report), [Specialization constants as Metal function constants](../../../docs/reference/rendering.md#specialization-constants-as-metal-function-constants), [Packed 16-bit formats and R4G4](../../../docs/reference/rendering.md#packed-16-bit-formats-and-r4g4), [Image clears and dynamic stencil state](../../../docs/reference/rendering.md#image-clears-and-dynamic-stencil-state), [Frees of descriptor sets whose pool is gone](../../../docs/reference/rendering.md#frees-of-descriptor-sets-whose-pool-is-gone), [Swap chain images destroyed by the game](../../../docs/reference/rendering.md#swap-chain-images-destroyed-by-the-game).

## Open

- Run on an iPad briefly, not on an iPhone; no device log taken yet.
- The JIT image holds only what the captures met: the boots, and the play captured on the Mac (the title, the file select, a new file's introduction, the castle grounds). A request it lacks is a `[RED]` line and the game crashes there; play that part in the Mac build (its run command writes `jit_capture/play`) and pack again.
