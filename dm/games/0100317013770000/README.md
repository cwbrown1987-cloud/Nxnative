# Mario + Rabbids Sparks of Hope (`0100317013770000`)

Update 1.6.2225577 (v393216) over the base game, SDK 13.3.5, Ubisoft Snowdrop on NVN. Modules `main` and `sdk`; verified build IDs are in [game.tsv](game.tsv). No game-specific rewriter patches were added.

## Status

Mac opening garden exploration tested: daylight, materials, shadows, quest HUD and left-stick movement. Two 180-second windowed runs of the standard base/update build, without mounted DLC or diagnostic shader overrides, exited cleanly with no new shader captures, pipeline-link failures or Metal validation errors. Audio devices opened for real output; audible output was not independently evaluated. An earlier ten-minute archive-based run also verified movement. The contributor also reports successful gameplay beyond the garden; the later route has not been independently documented or reproduced here, and a beginning-to-end playthrough is not complete.

After rebasing onto upstream `40b643b`, another 180-second windowed run with the rebuilt host and all 18,278 shaders reached garden rendering and exited cleanly with the same error checks. Movement was not reverified in that run.

The iPhone SDK source compile check passes (178 files). No IPA or iOS gameplay was tested; the README gallery labels the Mac validation. Remaining coverage is listed under [Open](#open).

## Standard Mac build

```sh
python3 scripts/build_ipa_from_nsp.py <NSP-folder> -k <prod.keys> --platform mac
```

The base game and update alone suffice. The normal build verifies the registered tables, builds the host and button font, and prepares all 16,053 pipeline pairs with zero failures. Full-library verification checks shader outputs, reports, stamps, generated bounds tables and vertex/pixel varying coverage. Original standard-build chain: `4fde39eeb5f1`; rebased validation chain: `e1bbf038fa18`; profile-input digest: `689b809fcbe9`.

The bounded smoke runs disabled background pipeline prebuild (`DM_PSO_PREBUILD=0`); standalone preparation completed separately. The normal launcher retains its defaults.

## What it needs

| Setting | Why |
|---|---|
| `mem_reserve 0x500000000`, `mem_alias 0x400000000` | Mac-tested 20 GiB virtual reservation with 16 GiB alias space; see [Memory](#memory) |
| `sys_resource 0x1000000` | 16 MiB declared by the NPDM; virtual address memory is available |
| `app_pool 0xCD500000`, `mem_stack 0x10000000` | Existing physical application-pool limit and stack capacity |
| `shader_groups /moria/=moria` | Base-game asset group; optional DLC shaders use build-local tables |

## Memory

**Resolved on Mac:** the game reserves a 12 GiB allocator region (`main+0x164308`, call at `+0x164310`) plus metadata. The provisional alias capacity was only 4.375 GiB; reservation failure left the region base zero and caused the fault at `main+0x164990`.

The tested layout above supplies virtual address capacity without increasing the physical pool or cutting the allocator. It is not a measured minimum or an iOS-tested layout.

## Files and shaders

The shared [Snowdrop reader](../../../docs/reference/shaders.md#snowdrop-westberg-v22-and-nvn-mcache-resources) extracts indexed `nvn/*.mcache` resources from WEST `.sdftoc` / BERG `.sdfdata` archives, in the verified Switch v22/zstd dialect.

| Asset set | Vertex | Pixel | Compute | Total | Coverage/pair rows |
|---|---:|---:|---:|---:|---:|
| Registered update v393216 | 15,968 | 2,029 | 281 | 18,278 | 16,053 |
| Update plus seven extracted DLC roots | 20,246 | 2,574 | 281 | 23,101 | 20,338 |

Both sets compile for Mac and supply all coverage partners' varying inputs. The registered profile does not require DLC; optional roots generate local tables while preserving registered executable settings and build IDs. The expanded set contains 92 exact stored program pairs; separable coverage rows describe default-varying requirements, not observed draws. Generated `c1_full.tsv` and `cb_extent.tsv` are library-bound and not committed.

All 505 diagnostic runtime control/code witnesses match archive records byte for byte. A streaming audit passed 298,859 compressed/multipart resources (11,558,951,121 decoded bytes), including 143 multipart resources. This establishes indexed extraction coverage, not execution of every shader.

**Resolved:** a 505-key partial build omitted cover pixel `de15e008f7ae4a04` and cached vertex `4104e02105ded5c3` without locn5. A full build reused it and failed with pixel `f02cd49a5be39e90`, despite correct pair rows. The [shared dependency fix](../../../docs/reference/shaders.md#partial-vertex-builds-include-their-pixel-dependencies) removes that failure.

## Rendering

**Resolved:** histogram clear `e1d1b7528487a1b3` targeted a dummy while atomics `2dbd29c9fdb93a54` updated the real 1,024-element R32UI pool. Read-only image rejection and buffer-type reflection were also corrected; shared mechanisms are linked under [Found on this game](#found-on-this-game).

**Resolved:** depth resolve `8b51be4f4ac51bac` (slot 3, R16Unorm 1600×900) and normal downsample `eb1465404ff41241` (slot 0, RGB10A2 800×450) originally produced zero images through dummy bindings. Writable-image preparation restores their outputs. Independent CPU comparison found zero RGB mismatches across all 360,000 downsampled normal texels; tone-map reconstruction matched GPU output within about 0.00097 on the 0–1 sRGB scale. No exposure clamp or lighting substitution was added. Later render-target use of initially sampled textures also passes attachment validation after the shared usage upgrade.

**Investigated:** 3D inputs retain a 1×1 2D placeholder during loading. Affected shaders: `ad34a496c970dff1`, `184b0b673101a2da`, `4143b4dfc3115f89`, `a5c80eb8e6380096`, `0ca739a46129f292` at texture slot 3; `e87cf6e1de373fa8` at slot 1. Every sample of these inputs is guarded by `fp_c3[24].x` (CB0 byte offset 384; nonzero or NaN enables it).

An isolated GPU checkpoint read the selected uniform pointers after each render pass and before deferred updates landed: all 418 recorded placeholder bindings had zero enable bits; all 6,606 real-3D bindings were enabled (150.0). The 150-second run reached the garden without validation errors. This is pass-end evidence for the recorded states, assuming the pass does not overwrite its own uniform storage, rather than an instruction-level trace of every sample. No dimension override, fallback or warning suppression was added. Temporary instrumentation stayed outside the repository and production cache.

## Mac routes

With an opening garden save: boot, dismiss prompts, select Continue and confirm A when visible. The task is “AN 'OVERALL' NICE DAY / Find Rabbid Mario's overalls!”. Left-stick movement changes position and camera. Cold pipeline preparation can take several minutes; fixed input delays can miss prompts.

## Found on this game

- [Album capture notification subscriptions](../../../docs/reference/services.md#album-capture-notification-subscriptions).
- [Image bindings follow reflected access and texture shape](../../../docs/reference/rendering.md#image-bindings-follow-reflected-access-and-texture-shape).
- [Buffer image stores preserve pool backing](../../../docs/reference/rendering.md#buffer-image-stores-lose-their-pool-backing-when-replaced-by-a-dummy).
- [Compute stores prepare writable texture usage](../../../docs/reference/rendering.md#compute-image-stores-rejected-by-initial-read-only-texture-usage).
- [Sampled textures later used as render targets](../../../docs/reference/rendering.md#a-sampled-texture-later-attached-as-a-render-target).
- [Snowdrop WEST/BERG reader](../../../docs/reference/shaders.md#snowdrop-westberg-v22-and-nvn-mcache-resources).
- [Partial shader build dependencies](../../../docs/reference/shaders.md#partial-vertex-builds-include-their-pixel-dependencies).

## Open

- Combat, later worlds and DLC gameplay; rendering beyond the tested opening route.
- The rebased run additionally warned for texture slot 3 of `35ac28bf364ad740`; its sampling predicate has not been GPU-checked. Any mismatch with an enabled sampling branch needs investigation. The integer-attribute format `0x27` fallback warning also remains.
- iOS shader compilation, device rendering and virtual address layout.
- Representative pipeline prewarm seeds; the seed manifest is empty.
