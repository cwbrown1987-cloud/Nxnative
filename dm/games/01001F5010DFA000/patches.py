# Pokémon Legends: Arceus (01001F5010DFA000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # Pokémon Legends: Arceus 1.0.0 (v0) main: nninitStartup (main+0x273cf10) sets a 16 MB heap for its own allocator, then malloc's StandardAllocator is initialized with virtual address
  # memory over 32 GB of address space (main+0x2b12cb0: Initialize(nullptr, 0x800000000, true)), which the Switch's 64 GB alias region holds and an iPhone's single 6 GB reservation cannot.
  # The allocator commits pages as it goes and the pool bounds what it maps, so 4 GB of address space holds it, as Pokémon Legends: Z-A's
  '7fcad279539de183b25c11834fd4a030': [
    (0x2b12cdc, '0201c0d2', '2200c0d2', 'StandardAllocator::Initialize(nullptr, size): address space mov x2,#0x800000000 → mov x2,#0x100000000 (32 GB → 4 GB)'),
  ],
}
