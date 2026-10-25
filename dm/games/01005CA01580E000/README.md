# Persona 5 Royal — experimental bring-up

This is a bring-up note for the general shader and NVN fixes, **not a registered game profile or a claim of full compatibility**. No game files, generated shader tables or compiled libraries are included.

## Observed build and scope

- Title `01005CA01580E000`, update `v65536` (1.0.2), `main` build `d4b150b29a931cd381e2a30318fc299f`, SDK 13.
- A locally generated provisional profile loaded `main`, `subsdk0` and `sdk`. The first startup failure was the texture-size assertion below.
- With these fixes on the original bring-up checkout: all 30,646 shader libraries built for macOS; title, menu, a new game, the first casino scene, movement and platform jumps were tested on an Apple M2 Pro. The tested gameplay segment ran at about 30 fps. The complete installed macOS bundle also reached its menu without missing-shader errors.
- On the current upstream base, extraction through its existing CPK/CRILAYLA reader yields the identical 30,646 shader keys; synthetic format, layout and Metal readback tests exercise the adapted changes. A complete game build from this upstream base has not been replayed. No iOS/device or later-game testing is claimed.

## Shaders

`CPK/ALL_USEU.CPK` has 94,631 entries. Nine `BASE/GFDNXHHPRESET*.GSC` cache members are CRILAYLA-compressed GFS0/GSC0 containers. Their HHNEEDLE records supply 30,418 unique stages. Another 228 stages are inline control/code pairs in `main`; only 108 are inside HHNEEDLE envelopes, so restricting extraction to the envelopes misses boot programs. Total: 1,114 vertex, 29,526 pixel and six compute shaders.

The records carry each control and code length; do not extend a 0x850-byte control into the following code to fill a presumed 0x880 bytes. Vertex and pixel programs are bound separately at runtime and need the splitter's varying cover.

## Found on this game

- [GFD shader caches and inline NVN programs](../../../docs/reference/shaders.md#gfd-gsc-shader-caches-and-inline-nvn-programs).
- [Linear render targets without LINEAR](../../../docs/reference/nvn-objects.md#linear-render-targets-without-linear): the 16x16 RGBA8 target with stride 128 was reported as 1,024 bytes instead of 2,048. `main+0x10189f4` asserted in `SetupSurfaceInfoMemoryInside`; the trap was at `main+0x1028fbc`.
- [Texture-region clears with partial colour masks](../../../docs/reference/rendering.md#texture-region-clears-with-partial-colour-masks): skipping the opening story movie issues a whole-level alpha-only clear of a 1920x1080 RGBA8 texture (mask `0x8`), which the load-action-only path rejected.

## Open

A registered profile, a reproducible complete build on the current upstream chain, later gameplay, full rendering comparison, and an iOS run remain to be validated. The original provisional profile leaves conditional rendering at its default; a short comparison with it enabled did not establish a visible improvement.
