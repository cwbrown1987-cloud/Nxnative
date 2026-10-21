# Breath of the Wild: Mac world-load crash and frame pacing

These changes address the 1.9.0 build (`01007EF00011E000`) on Apple Silicon Mac.
The tested local build uses a 60 fps target on an M5 and a 165 Hz display.
It retains the game's original models, existing integer game-step stubs and
explicit VFR scene overrides.

## World-load crash: resource heap headroom

The task-worker null write at `main+0x155a7a4` follows an allocation at
`main+0x155a79c`. Local heap diagnostics identified the resource as
`Model/Obj_TreeConiferous.bfres`: its heap had only `0x70` free when model setup
requested another `0x78` bytes for a material texture deduplication entry.
Its RSTB entry was `0x29e520`; the decompressed file occupied `0x19b010` bytes.
Changing frame pacing alone did not eliminate this failure.

Generate an overlay from your own extracted RomFS:

```sh
python3 scripts/botw_model_heap_overlay.py "$ROMFS" "$OVERLAY_DIR"
```

The script adds 64 KiB to non-texture `Model/*.bfres` resource sizes and 512 KiB
to `Model/Obj_TreeConiferous.bfres`. It handles CRC and named table entries,
preserves all other entries, and writes a valid literal-only Yaz0 stream at
`System/Resource/ResourceSizeTable.product.srsizetable` under the overlay.
It never rewrites the source RomFS. Regenerate from the original RomFS rather
than feeding an already padded overlay back into the script.

Use the existing `DM_ROMFS_OVERLAY` setting to select the generated directory.
For a Mac host launched from the terminal:

```sh
DM_ROMFS_OVERLAY="$OVERLAY_DIR" DM_FPS_TARGET=60 DM_FRAME_PACING=responsive \
    dm/host/dmhost "$PATCHED_MODULE_DIR"
```

Keep your usual game, shader, font and save paths in the environment. For an
app wrapper, pass the same three settings before starting the host.

This is a resource-budget workaround, not a host allocator replacement. The
tested table changes 3,903 model entries; the additional budget would total
244.4 MiB if all were loaded simultaneously. Actual residency depends on the
loaded scene. Memory-constrained devices and other regions need separate tests.
No game table, model, key, shader or save is included in the source change.

## Frame pacing: recover immediately after transient work

`DM_FRAME_PACING=responsive` keeps presentation at the requested 60/30 cap,
rather than selecting a 30/20 fps hold after three late frames and waiting for
consecutive-fit trials to climb back. A late frame is followed by the next
available frame; real CPU/GPU work can still lower the achieved frame rate.

Simulation still advances in the existing 1/60 s integer units. Elapsed-time
compensation is independent of the presentation hold, and retains at most two
vsyncs of debt after a load or pause to avoid a long fast-forward. It does not
introduce fractional physics steps, interpolated frames or a separate render
thread. `DM_FRAME_PACING=adaptive` remains the default; fixed VFR scenes and
an explicit 30 fps cap remain supported in both modes.

The adaptive mode also gains display-only lateness slack on Mac screens whose
refresh rate is not a multiple of 60. At 165 Hz, a nominal 50 ms frame alternates
between roughly 48.48 and 54.55 ms. The original 1.67 ms tolerance repeatedly
cleared its recovery count despite cheap CPU/GPU work. One physical refresh of
additional presentation slack permits recovery without relaxing the work-cost
threshold.

A display link requested at 60 Hz can run at 55 Hz on a 165 Hz screen. On such
screens the link now uses the screen's native rate and counts virtual 1/60 s
ticks. `DM_LINK_VTICK=0` retains the system's rate selection. Integer-multiple
screens keep their prior behavior.

## Uniform-buffer updates: avoid unnecessary render-pass splits

BotW binds 64 KiB uniform ranges but often updates only 16-64 bytes before each
draw. The old coverage check ended about 225 extra passes per frame. The host
now conservatively scans cached MSL for literal uniform-array reads and shadows
only the required range. Computed indices, unrecognized source and missing MSL
fall back to the entire binding.

Unmodified gaps are resolved from the most recent queued inline writes or from
memory after earlier submissions complete. Pending copies/fills, unknown writes
and in-flight work keep the existing pass-ending fallback. Local shrine
measurements showed GPU median time falling from 14.5 to about 5.0 ms. Shader
translation and cache-chain versions are unchanged by this patch.

## Validation and limits

The gameplay measurements below come from the locally tested source based on
`1a11d0a`; the PR is rebased onto current upstream `main`. They are not a new
full-game benchmark of the rebased tree.

| Copied-save world-load test | Targeted null-write failures | Duration per trial |
| --- | --- | --- |
| Original RSTB, responsive 60 fps | 3 / 7 | up to 45 seconds |
| Padded RSTB, responsive 60 fps | 0 / 12 | 45 seconds |

Every overlay trial reached the world and exercised movement/camera input.
The last logged frame-rate sample in each ranged from 56.0 to 60.1 fps; none
logged a host hold change. Each trial deliberately ended via the `DM_WATCH`
SIGALRM timeout, which is excluded from the targeted crash count. These are
short opening-area trials, not evidence of full-game or long-session stability.
The user also confirmed that the repaired local version resolved the symptoms.

Separate same-save shrine measurements before the overlay work showed:

| Configuration | Movement at 35-60 s, average | Steady segment at 60-120 s, average |
| --- | --- | --- |
| Original adaptive controller | 19.41 fps | 19.98 fps |
| Adaptive with refresh-jitter recovery fix | 49.13 fps | 59.92 fps |

Loading and first-use stalls can still happen; responsive pacing prevents the
controller from extending them into a deliberately slower hold. It does not
remove the underlying loading work or guarantee 60 fps in every scene.

Automated checks:

```sh
make -C dm/host GAME=01007EF00011E000 -j8 dmhost
make -C dm/gfx/tests GAME=01007EF00011E000 t_nvn t_fstep t_responsive
dm/gfx/tests/t_nvn
dm/gfx/tests/t_fstep
dm/gfx/tests/t_responsive
python3 -m unittest discover -s scripts/tests -v
```

The frame-step suites cover the old 165 Hz lockout, recovery, sustained load,
game-time compensation, bounded hitch recovery, explicit scene overrides and
cap changes. The Python tests use synthetic Yaz0/RSTB data only. The generated
overlay was also checked byte-for-byte against the successful local build's
overlay.
