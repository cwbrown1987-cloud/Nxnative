# Super Mario 3D All-Stars, program 2 (Super Mario Sunshine, 010049900F546002): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py
# and applies those of a module's NSO build ID; CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # 1.0.0 (v0) main: Hagi reserves its coroutine stacks as one 1 GB address region (main+0x14b02c → main+0x157940, the size at main+0x14b034) after the 4 GB + 2 MB region
  # that maps the GameCube, and hands them out with a bump allocator (main+0x157a00, the top at pool +0x10). Measured on the Mac through boot, the opening and Delfino Airstrip:
  # twelve 64 KB stacks and nineteen 64 KB blocks at the pool's start (main+0x1579a0), under 2 MB. 64 MB keeps both regions in a 4.25 GB alias region, so the whole guest block
  # fits the 6 GB iOS allows one reservation
  'ed0d7ace84eec7807225034ad8a30cfd': [
    (0x14b034, 'e2030232', '0280a052', 'coroutine stack region size: orr w2,wzr,#0x40000000 → mov w2,#0x4000000 (1 GB → 64 MB)'),
  ],
}
