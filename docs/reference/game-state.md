# Game state

The games' own state: saves, scripted state, and behaviour that looks like a host bug but is not. Each entry: symptom, cause, fix, the games it was found on. The [symptom index](../agents/symptoms.md) lists every symptom.

## Game behaviour that is not a host bug

### Most draws are in command buffers replayed later

- **Symptom:** "stuck" at a screen with one draw per frame.
- **Cause:** usually not stuck: most draws are in recorded command buffers replayed later.
- **Fix:** dump the passes (`DM_NVN_PASSDUMP`, [04, Diagnostic switches](../agents/04-graphics.md#7-diagnostic-switches-host)) before assuming the game logic is blocked.

### Buttons mapped by position: B confirms

- **Symptom:** menus ignore A.
- **Cause:** not a host fault: the game maps its buttons by position, B confirms and A goes back (its prompts say so).
- **Found on:** [DARK SOULS: REMASTERED](../../dm/games/01004AB00A260000/README.md) (SDK 4.5.0). The first boot shows two notices before the title menu ("Unable to connect to the network", then "Game will start in offline mode"), and a new game first walks through Brightness, Options and Button settings.

### Any Lua error quits a LÖVE game

- **Symptom:** a crash in `main+0x339c00` a second or two into the title, in love-nx's video module teardown (`love::video::theora::Video` → `~Worker`; its thread released the worker that the closing module deletes too).
- **Cause:** the Lua state was closing: on the Switch, Balatro's `love.errhand` returns at once, so any Lua error quits. A `print` at the top of `love.errhand` in a copy of the RomFS (`DM_ROMFS=<copy>`) gave the error: `Shader uniform 'distortion_fac' does not exist` (the capture run had no shader library, so every program linked with no uniforms), then `bad argument #2 to 'send' (number expected, got boolean)` (a `bool` uniform reported as `GL_UNSIGNED_INT`).
- **Fix:** look for the Lua error first; the two errors here were host faults in the GL layer's shaders and uniforms (see [GL shaders put together at run time and captured](rendering.md#gl-shaders-put-together-at-run-time-and-captured) and [GL uniforms, pipelines and attributes](rendering.md#gl-uniforms-pipelines-and-attributes)).
- **Found on:** [Balatro](../../dm/games/0100CD801CE5E000/README.md) (SDK 18.3.2, LÖVE 11.4; one boot).
- **Check:** probing the destructors (`DM_PROBE`) and logging every object the Lua GC released (`DM_PROBE=main:0x18b920@x0+0`: the module proxies all at once) showed it was a shutdown, not a premature collection.

### TV latency calibration's late, beat-timed listening window

- **Symptom:** the TV latency calibration ("press A when you hear the fourth beat") ignores A.
- **Cause (not a host bug):** docked, the first boot runs it (scene script `main+0x4c0820`). It starts listening only `0x3c0` frames (16 s) after the prompt, through the active controller (`main+0x22b0` id `0x3ed`, virtual button 4 = A), and passes when about ten presses keep a steady offset within −5 to +13 frames of the cue (evaluation `main+0x2948c0`; offset = cue ticks at `+0x34` / about 17 ticks per frame, about 480 per beat).
- **Testing it:** scripted presses at fixed seconds drift off the beat; use frame-timed `DM_KEYS` at the bar period (117.12 frames at its 123 BPM) and read each press's offset with `DM_PROBE=main:2951f0@34`. A passed calibration is saved per TV panel identity (the host's all-zero one included, [Default display panel identifier](services.md#default-display-panel-identifier)) and not asked again.
- **Profile:** it plays handheld with Boost (`op_mode handheld`, `perf_mode boost`), which skips the TV setup and keeps the 1080p draw size.
- **Found on:** [Rhythm Heaven Groove](../../dm/games/0100D9F01D474000/README.md) (SDK 21.4.0).

## The input

### The keyboard does not reach the game

- **Symptom:** the keyboard does nothing in the game, while the scripted input works.
- **Cause:** the two do not share a path: `DM_KEYS` goes through player 1's controller (`dm_pad_set` in `dm/host/hle_hid.c`), the Mac keyboard through the front end's own mapping (`dm/host/front_mac.m`'s `on_key` → `key_bit`), and the two are only combined at `dm_pad_set_player`. A scripted run that works therefore says nothing about the keyboard.
- **Fix:** `DM_KBD_LOG=1` in the front end logs every key event with the state of the input: `[kbd] key 38 down (input on)` (38 = J, the A button). `input released` means the window was not key (the input is released while it is not), which is the other way a key goes missing. The key map is the Nintendo layout: J=A, K=B, U=X, I=Y, Q=L, E=R, Z=ZL, C=ZR, the arrow keys are the D-pad, WASD the left stick, F and G press the sticks.
- **Found on:** [FINAL FANTASY RESONANCE (Korean release)](../../dm/games/0100B8A026F14000/README.md) (the first run that used the keyboard rather than the scripted input).

### A stick command in `DM_CTL` looks like it did nothing

- **Symptom:** `key LUp~4` in the host's `DM_CTL` control channel does not move the character, and the log says `press 0`.
- **Cause:** `press 0` is the **button mask** (a stick is not a button), not a failure: the stick was pushed to the full deflection. The line prints the sticks too now.
- **Fix:** the stick names are `LLeft LUp LRight LDown` and `RLeft RUp RRight RDown`; a command holds them for its time (`~4` is four seconds). `DM_CTL` is a file the host reads (every 100 ms): `shot <path>` saves a frame, `passdump <n>` the render passes, `key` a button or a stick, `cvarf` a console variable (`dm/host/hle_hid.c`).
- **Found on:** [FINAL FANTASY RESONANCE (Korean release)](../../dm/games/0100B8A026F14000/README.md).

## Scripted state

### The software keyboard in scripted runs (`DM_KBD`)

- **Symptom:** in a scripted run, a screen goes back by itself right after a confirm; the log shows `swkbd: … → no window, treated as cancel`.
- **Cause:** the confirm opened the system keyboard (`swkbd`, name entry). Without a window the host answers "cancel" by design.
- **Fix:** pass `DM_KBD=<text>` to answer it.
- **Found on:** [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md) (its appearance choice).

### Player join screens (`hid::StartLrAssignmentMode`)

- **Symptom:** a player join screen that ignores A (a character select with four "L + R to join" slots after the title).
- **Cause:** the game calls `hid::StartLrAssignmentMode` and waits for L and R pressed together on the join screen itself, then a character choice with A.
- **Fix:** in `DM_KEYS` that is `L+R~0.5` while the screen is up (presses on the title before it are lost).
- **Found on:** [Super Mario 3D World + Bowser's Fury](../../dm/games/010028600EBDA000/README.md).
- **Note:** on the game select, holding the stick right for a second (`7:LRight~1`) switches to Bowser's Fury, which also uses `nvnTextureGetSwizzle` and `nvnTextureGetStorageClass`. Map and level movement read the left stick only: `DM_KEYS` takes `LLeft` / `LUp` / `LRight` / `LDown`. A working route into World 1-1 on a fresh save: `DM_KEYS=6:A,10:A,14:L+R~0.5,17:A*3/2,24:Plus*6/3,45:A*6/3,66:LUp~1,70:A,74:LRight~1,78:A,82:LLeft~1,86:A` (World 1-1 by frame ~6000).
