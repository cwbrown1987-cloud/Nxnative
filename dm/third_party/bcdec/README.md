# bcdec

A single-file BC1–BC7 block decoder by Sergii "iOrange" Kudlai.

- Version: v0.985 (the version in the header), unmodified.
- Source: https://github.com/iOrange/bcdec
- License: MIT or the Unlicense, at your choice; see `LICENSE` (the same text ends `bcdec.h`).
- Used by: `dm/gfx/nvn/nvn_mtl.m`, the CPU fallback for devices without hardware BC texture sampling (iPhone A16 and older) and for the offline BC-to-ASTC cache. The implementation is compiled in `nvn_mtl.m` with `BCDEC_IMPLEMENTATION`.
