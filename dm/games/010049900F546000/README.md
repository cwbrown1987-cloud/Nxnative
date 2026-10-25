# Super Mario 3D All-Stars (`010049900F546000`)

Base game 1.0.0 (v0, no update), SDK 9.5.1. This profile is program 0, the launcher: Nintendo's sead / agl / gsys with NintendoWare's layout library on **NVN**. Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`. The collection is a multi-program application: the launcher starts [Super Mario 64](../010049900F546001/README.md) (program 1), [Super Mario Sunshine](../010049900F546002/README.md) (program 2) and Super Mario Galaxy (program 3) with `oe::ExecuteProgram`. Each program is its own Program NCA under the title ID base + index, with its own profile, build and `<id>_build` (`nx_extract --program N`, `build_ipa_from_nsp.py --program N`). Galaxy's program is 32-bit ARM (its NPDM's 64-bit flag is clear, Elf32 dynamic sections), which Apple silicon cannot run, so it has no profile. Plays on the Mac; the iPhone IPA (one app of programs 0, 1 and 2, 2.6 GB) is built and not yet run on a device.

On the Mac, from the one run command of a Mac build ([How the programs hand over](#how-the-programs-hand-over)): the opening movie, the title, every menu tile with its movie, a soundtrack's track list, the language list; A on Super Mario 64 or Sunshine starts that program with the launcher's parameters, and each game's "Return to title selection" brings the launcher back. Menu frames 16.66 ms p50 (59.2 fps); 550 MB resident at the menu, 362 MB of it GPU allocations.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `render_cond on` | [`game.tsv`](game.tsv) | the menu wraps its clears in conditional rendering; without evaluating it every frame is black ([Rendering](#rendering)) |
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | the partition of the other sead games without virtual address memory (256 MB in front + 256 MB alias region + 256 MB stack region + 3.25 GB heap region); `main` sets a 2.93 GB heap |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares no system resource (META +0x14 = 0) |
| `modules main subsdk0 sdk` | `game.tsv` | load order as on Horizon; `subsdk0` plays the menu's movies |
| Cut of `main+0xc040` | [`patches.py`](patches.py), `main` build `ff44f58218c6…` | Galaxy's tile cannot be started ([Galaxy's tile](#galaxys-tile)) |
| `zip_store .bwav:.mp4:.zs:.metallib` | `game.tsv` | already-compressed files stored as they are in the IPA |

## Files and shaders

- RomFS: zstd-compressed SARC archives (`.zs`); the opening (`MovieData/LauncherOpening.mp4`) and each tile's artwork (`BgMovie64.mp4`, `BgMovieSunshine.mp4`, `BgMovieGalaxy.mp4`) are H.264 MP4 movies through the SDK's movie library. `romfs_marker` is `MovieData/BgMovieGalaxy.mp4`.
- 3,899 shaders: agl's and gsys's sharcb in `Lib`, BNSH in `ShaderData` and the layouts, and 40 in `main`.
- Two HtmlDocument NCAs (`html0`, `html1`), which the packing extracts beside the RomFS with every program's pages.
- A prewarm list recorded on the Mac from a fresh save (`DM_PSO_MANIFEST=off DM_PSO_RECORD`): the opening movie, the title, every menu tile, a soundtrack's track list, the language list and the start of Sunshine; 22 shaders and 16 pipelines. With it a fresh run built no pipeline on demand on that route (prewarm 307 ms in the background).

## Rendering

- **Resolved: every frame black.** The menu wraps its clears in conditional rendering, as Tears of the Kingdom does: `render_cond on` ([Conditional rendering evaluated at replay](../../../docs/reference/rendering.md#conditional-rendering-evaluated-at-replay)).
- **Resolved: flat lavender where each game's artwork belongs.** Decoding worked (the Y and UV planes reached their textures, `texraw`). agl converts each frame into an RGBA texture with its YUV program (`agl_common` `bf1135fd591c81ef`), then a second draw in the same pass, with no barrier between, corrects the gamma in place (`021631192bc452b6`, exponent 2.2), sampling the texture it renders into. On Metal that sample read the memory from before the pass, the zeros the gamma draw had stored the frame before, so every movie stayed transparent over the layout target's clear colour (0.3, 0.3, 1, lavender after the sRGB view). `DM_NVN_HILITE` on the YUV program and `texdump` showed nothing landing, because the gamma draw overwrote it. Fixed for every game by [An attachment sampled after its pass wrote it gets a snapshot](../../../docs/reference/rendering.md#an-attachment-sampled-after-its-pass-wrote-it-gets-a-snapshot): one snapshot a frame here (the gamma draw, 1440x1080 RGBA8), and no other draw took one.

## Fonts

- **Resolved: a crash at boot with the null glyph (`main+0x62d20`).** The launcher looks up U+E06B of the extension shared font, which the host's stand-in did not draw ([Every undrawn extension code point is a ring](../../../docs/reference/services.md#every-undrawn-extension-code-point-is-a-ring)).

## Galaxy's tile

- Pressing A on Galaxy's tile called `oe::ExecuteProgram(3)`, a 32-bit program. The menu's contents are 0–2 the games (program = content + 1, `main+0xe710`) and 3–5 their soundtracks. Each frame its select state (`main+0xf090`) asks `main+0xc040`: "the selected tile can be decided (`main+0xadc0`) and A was just pressed (`main+0x151e0`)"; if so it runs the decide action (`main+0xaf90`) and the next state starts the game or opens the soundtrack's player. The cut rewrites that function in its own 24 words to read the selected content as `main+0xacf0` does and answer false for content 2. Found with `DM_PROBE` on `setNerve` (`main+0x421c40`): A on Galaxy set nerve `main+0x752130` from that state, then `main+0x752128`, which ends in `ExecuteProgram`; a first try on `main+0xacf0` changed nothing, since the A press does not ask it.
- Galaxy's tile, artwork, description, language list and soundtrack (content 5, played in the launcher) stay: hiding the tile would mean rewriting the six-tile carousel and its layout animations.

## How the programs hand over

- The launcher hands each game a 16-byte launch parameter: its LanguageCode and two volume floats (`main+0x10824`; "en-US", 0.5 and 1.0), which the game pops with `oe::TryPopLaunchParameter`. Each game's pause menu is an offline web page whose "Return to title selection" ends at `http://localhost/return_to_launcher`; the game then calls `ExecuteProgram(0)`.
- **Mac:** a Mac build from program 0 packs every program that has a profile (0, 1 and 2; `--programs 0,2` lists them), writes `programs.tsv` in program 0's work folder and prints one run command with `DM_PROGRAMS`. `ExecuteProgram` ends the program and starts the named program's host in its place ([Multi-program applications: `oe::ExecuteProgram`](../../../docs/reference/services.md#multi-program-applications-oeexecuteprogram)).
- **iPhone:** one app holds every program; it starts the program the last `ExecuteProgram` recorded (`Documents/program.bin`), else the launcher. On `ExecuteProgram` it shows "Starting <name>…" (the profile's name: "Super Mario 3D All-Stars: Sunshine", "… Super Mario 64", "Super Mario 3D All-Stars" on the way back), schedules a notification "Tap to start <name>" and quits; tapping it opens the app on that program. Permission is asked at the first start; without it the app just quits. The saves are one `Documents/save` for all programs.
- **In process:** with `DM_PROGRAM_SWITCH=inproc` the next program boots in the same process in about 0.1 s ([In-process program switch](../../../docs/reference/services.md#in-process-program-switch-dm_program_switchinproc)); on the Mac it needs one host over the three profiles, `make -C dm/host PROGRAMS="0=010049900F546000 1=010049900F546001 2=010049900F546002"`. Measured on the Mac (headless, one host over programs 0, 1 and 2): 10 cycles of launcher → Sunshine → launcher → Super Mario 64 → launcher, 40 switches, no crash; ending a run took 7 ms on average for the guest threads (at most 21) and 128 ms in all (at most 230). The launcher's footprint at its title, 12 s after `nnMain`, was 544 MB at the first start and 537–674 MB after each cycle, threads 30 to 33. `SuperMario3DAllStars-inproc.ipa` (`--env-file` with that line in `dm/env.txt`) is such a build for the iPhone.

## Mac input

- With `DM_CTL`: A at the title, then A on Super Mario 64 (the first tile), or Right and A for Sunshine. `program <n>` calls `ExecuteProgram(n)` from the control thread; a headless run has no web view, and the stand-in page closes as soon as it appears, so `program 0` is the way back there ([05, Scripted input](../../../docs/agents/05-debugging.md#scripted-input-and-thread-scheduling): how the control file is read after each kind of switch, and raising the window before a `shot`).

## Found on this game

General host changes first needed here; each applies to every game:

- **Same-pass snapshot of a written attachment** (`g_fb_wrote`, `fb_note_draw`, `t_fb_stale`): [An attachment sampled after its pass wrote it gets a snapshot](../../../docs/reference/rendering.md#an-attachment-sampled-after-its-pass-wrote-it-gets-a-snapshot).
- **The extension font's ring for undrawn code points** (`make_ext_font.py`): [Every undrawn extension code point is a ring](../../../docs/reference/services.md#every-undrawn-extension-code-point-is-a-ring).
- **Multi-program applications** (`nx_extract --program`, `--programs`, `DM_PROGRAMS`, `DM_LAUNCH_PARAM`, `DM_EXEC_OUT`, one iPhone app over several profiles, the hand-off notification): [Multi-program applications: `oe::ExecuteProgram`](../../../docs/reference/services.md#multi-program-applications-oeexecuteprogram).
- **In-process program switch** (`progswitch.c`, per-run statics, guest thread termination, end-of-run releases): [In-process program switch](../../../docs/reference/services.md#in-process-program-switch-dm_program_switchinproc).

## Open

- Not run on an iPhone: the app's program choice (`main.m`), the notification hand-off and the in-process switch, where the restore runs on the UIKit main thread, the modules are remaps of the executable's sections and the fence makes remapped `__TEXT` pages read-only.
- The in-process switch: small allocations grow by about 7 MB per cycle (malloc small 12 → 89 MB over 10 cycles), and `leaks` finds about 0.7 MB unreachable after a Super Mario 64 round trip. The fallback after a guest thread that does not leave was not exercised in a game run (`t_thread_term` checks it).
- Galaxy (program 3) cannot run: 32-bit ARM.
