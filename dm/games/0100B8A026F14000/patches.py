# FINAL FANTASY RESONANCE (0100B8A026F14000, the Korean release; the Japanese one is 0100606026F12000): the rewriter's patches of this game's own builds.
# dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID; CUTS, OBS and FRAME_STEP as described there ("Registered patches").
# Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py.
CUTS = {
  # FINAL FANTASY RESONANCE 1.0.1 (v65536) main: Unreal Engine 5.6.1 constructs its FMallocBinned3 in place, as Octopath Traveler 0's:
  # nninitStartup (main+0x13370) reserves the engine region (62 GB unless -SwitchVirtualAddressSpaceSize= caps it, main+0x137d0), then calls the constructor on main+0x77c6210
  # (bss; main+0x137f0 → main+0xae770), which reserves 38 GB of address space for its pools (main+0xae82c: the size 0x980000000 is hardcoded in the game and does not
  # follow -SwitchVirtualAddressSpaceSize=, so that switch cannot help). The call is cut; the host puts its allocator's vtable in the object before any guest code runs
  # (hle_uemalloc.c, layout UE5_6: the vtable at main+0x67df800 has 32 slots). FPlatformMemory::BaseAllocator (main+0x13c64) returns the object and the thread-local storage
  # allocator (main+0x13830 / main+0x13870) calls its Malloc / Free slots; its pool base (main+0x7c148a0) and page size (main+0x7c14800) are read only by the allocator's own code.
  # The Japanese release (main build 84e182f72ee1da4f477804bd05b54c15) has the same code at the same offsets; only the resources differ.
  'b7f965b9d7227db8e29f04e84ea7331b': [
    (0x137f0, 'e06b0294', '1f2003d5', 'nninitStartup: bl 0xae770 (FMallocBinned3 constructor, 38 GB of address space) → nop; the host allocator is in the object already (hle_uemalloc.c)'),
  ],
}
