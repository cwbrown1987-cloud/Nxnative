# Xenoblade Chronicles: Definitive Edition (`0100FF500E34A000`)

Update 1.1.2 (v196608), SDK 9.3.1, Monolith's engine on NVN. Main build
`92c78bb3dcbbc3f7a3caf601d7b85f7a`. The profile retains original 720p/30fps behavior.
Resolution/timing upgrades are a separate contribution. The general float32
padding fix was contributed in [PR #365](https://github.com/seedds/nxnative/pull/365).

## Mac validation

The original local integration was played through the opening battle and Colony 9.
The clean current-upstream port was then checked on a copied first manual save:
terrain, movement, menus and the bridge dialogue, including Shulk's reply. The
player confirms stable models after the primitive-ordering fix below, with normal
rendering paths enabled. Original behavior is 720p/30fps; full game and iOS untested.
All 15,135 shaders compile for Mac and iOS; compilation is not an iOS gameplay test.

The static/title regression comparison covers this title only. Other games are
unchecked locally. A known upstream Metal archive/deployment incompatibility in
`t_pso_bundle` reproduces on the unchanged baseline; it is separate from this game.

## Graphics

Use upstream's HCPS/XBC1 reader and rasterizer-discard vertex-storage path.
The packed RG32Uint probe list needs integer OR accumulation, with COPY kept
separate. Five measured occupancy writers also require early depth/stencil
rejection before image side effects; shader_facts_manual.tsv records those facts.
These are opt-in observations, not a claim to decode the NVN early-test flag.
Do not extend them to other shaders without scene evidence.

A Float3 position in the first depth-of-field draw is read through a uint4
shader declaration. Correct float padding is needed for its missing w; the old
UInt3 reinterpretation clips the fullscreen draw and blends black over the
background during Shulk's bridge reply. The separate general padding PR fixes it.

Resolved: models flickered or stretched on the clean upstream port when a
vertex-only palette update raced an earlier model draw reading that storage.
The pending primitive-barrier fix orders the reader before the later writer.
The GPU regression failed before the fix and passes in both barrier modes;
the player confirms the corrected bridge and movement behavior.

## Reproduction

Build the supplied base game plus update 1.1.2 through scripts/build_ipa_from_nsp.py
with --platform mac-app. Use your own packages and keys. At Colony 9, the second
displayed save is the first manual slot (after autosave). Check terrain lighting,
then approach the bridge and inspect Shulk's first reply. No saves are shipped.
Keyboard: J=A, K=B, WASD movement, arrows D-pad, Q/E=L/R, Return=Plus.

## Found on this game

- [Float32 padding through integer inputs](../../../docs/reference/rendering.md#float32-vertex-padding-through-integer-inputs).
- [Integer OR lists and early occupancy rejection](../../../docs/reference/rendering.md#integer-or-lighting-lists-and-early-occupancy-rejection).
- [Primitive barriers before a later shader writer](../../../docs/reference/rendering.md#primitive-barriers-before-a-later-shader-writer).
