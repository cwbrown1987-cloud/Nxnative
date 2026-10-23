# Super Smash Bros. Ultimate (01006A800016E000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # Super Smash Bros. Ultimate 13.0.5 (v2031616) main: the game's virtual allocator (behind nu::VirtualAllocHook; set up at main+0x37c9a20 during the static initialisers)
  # reserves 62 GB of address space, AllocateAddressRegion(&base, 0xf80000000), which the Switch's 64 GB alias region holds and an iPhone's single 6 GB reservation cannot;
  # when it fails the game aborts (main+0x37c9bd0). The region is a page allocator in 64 KB units: its last 14 MB hold the allocator's own tables (header at base + 0xf7f200000,
  # grown 64 KB at a time with AllocateMemoryPages up to the region's end, main+0x37c9c50 / +0x37ca3cc / +0x37caf68) and the 0xf7f20 pages before them are handed out
  # (main+0x37c9b98: count passed to main+0x37c9c00). Every place that derives from the size is cut to a 3 GB region, the header at base + 0xbf200000 and 0xbf20 pages
  # (a starting point, to be measured: nothing yet says how much the game maps)
  '21450c647b8c5940ed5b68218ea128fd': [
    (0x37c9a5c, 'e11361b2', '0100b8d2', 'AllocateAddressRegion size: mov x1,#0xf80000000 → mov x1,#0xc0000000 (62 GB → 3 GB)'),
    (0x37c9a6c, 'e97f7cb2', '09fe9fd2', 'header + 0xfff0, low part: mov x9,#0xffffffff0 → mov x9,#0xfff0'),
    (0x37c9a70, '0be4afd2', '0be4b7d2', 'header offset: mov x11,#0x7f200000 → mov x11,#0xbf200000'),
    (0x37c9a74, '09e4aff2', '09e4b7f2', 'header + 0xfff0: movk x9,#0x7f20,lsl #16 → movk x9,#0xbf20,lsl #16 (0xf7f20fff0 → 0xbf20fff0)'),
    (0x37c9a78, 'eb01c0f2', '0b00c0f2', 'header offset, high part: movk x11,#0xf,lsl #32 → movk x11,#0,lsl #32 (0xf7f200000 → 0xbf200000)'),
    (0x37c9a9c, 'e91361b2', '0900b8d2', 'region end for the first header page: mov x9,#0xf80000000 → mov x9,#0xc0000000'),
    (0x37c9b98, '01e48f52', '01e49752', 'page count, low part: mov w1,#0x7f20 → mov w1,#0xbf20'),
    (0x37c9b9c, 'e101a072', '0100a072', 'page count, high part: movk w1,#0xf,lsl #16 → movk w1,#0,lsl #16 (0xf7f20 → 0xbf20 pages of 64 KB)'),
    (0x37c9c50, 'e91361b2', '0900b8d2', 'region end when the header grows: mov x9,#0xf80000000 → mov x9,#0xc0000000'),
    (0x37ca3cc, 'e81361b2', '0800b8d2', 'region end when the header grows: mov x8,#0xf80000000 → mov x8,#0xc0000000'),
    (0x37caf68, 'e91361b2', '0900b8d2', 'region end when the header grows: mov x9,#0xf80000000 → mov x9,#0xc0000000'),
  ],
}
