// Persona 5 Royal's Rsdx allocates a 16x16 RGBA8 linear render target with
// LINEAR_RENDER_TARGET alone. Storage must agree with the 128-byte row pitch
// reported by DeviceGetInteger, or SetupSurfaceInfoMemoryInside aborts.
#include "../nvn/nvn_tex.h"
#include "../tex/nvn_deswizzle.h"
#include <stdio.h>

static int failed;
static void check(int ok, const char *name) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
    failed += !ok;
}

int main(void) {
    nvn_texdesc d = {.target=1, .format=0x25, .width=16, .height=16,
                    .depth=1, .levels=1, .samples=1};
    nvn_texlayout l;
    nvn_tex_layout(&d, &l);
    check(l.size == 1024 && l.align == 512, "ordinary block-linear storage");
    d.flags = 0x10;
    nvn_tex_layout(&d, &l);
    check(l.size == 1024 && l.align == 32, "ordinary linear storage");
    d.flags = 0x4c; d.stride = 128;
    nvn_tex_layout(&d, &l);
    check(l.size == 2048 && l.layer_size == 2048 && l.align == 128,
          "P5R render target uses its explicit row pitch without LINEAR");
    check(nvn_tex_level_offset(&d, 1) == 0 && nvn_tex_level_gobs(&d, 0) == 0,
          "linear render targets have no block-linear level geometry");
    uint32_t row, rows, slices, bpb; uint64_t base; unsigned th, td;
    check(nvn_deswizzle_geom(&d, 0, 0, &row, &rows, &slices, &base, &th, &td, &bpb) == -1,
          "linear render targets never enter the block-linear decoder");
    d.stride = 0;
    nvn_tex_layout(&d, &l);
    check(l.size == 2048 && l.align == 128, "implicit render target row pitch");
    d.flags |= 0x10; d.stride = 256;
    nvn_tex_layout(&d, &l);
    check(l.size == 4096 && l.align == 128, "combined flags preserve an explicit pitch");
    return failed ? 1 : 0;
}
