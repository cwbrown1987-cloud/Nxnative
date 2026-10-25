# Xenoblade Chronicles 2 3.0.0 (JP 0100F3400332C000, main build FEEE7AFA8A1541BD): frame rates other than the game's 30, after masagrator's FPSLocker config for this build
# (FPSLocker-Warehouse patches/0100F3400332C000/FEEE7AFA8A1541BD.yaml; the US 3.0.0 build has the same offsets). The game steps its world by a fixed 1/30 s; the stub at main+0x7009e4
# measures the real frame time instead, clamps it to [1/target, 2/target] and stores it where the game reads its step ([main+0xb900d0]+0x78/+0x7c, only while that field holds a
# frame time; in this JP build writing there made a worker thread assert on NaNs whenever the stub ran, so those two stores are left out (no1) and only [main+0xc232c8]+0x80
# and the wind get the step), so the game
# runs at real speed at any rate. The wind reads the same step (main+0x748658), and the dynamic-resolution budget a per-frame time the host derives from the rate (main+0x6aaabc).
# State page (patch_nso.py "Frame step"): +0x38 float step, +0x40 u64 last counter, +0x48 float resolution budget, +0x4c float effective target fps; the host writes +0x48 / +0x4c and the
# game's present interval (main+0xb75c40, two u32) every present (hle_fpslock.c xc2_tick), and holds 30 while a cutscene plays (u8 main+0xbd8f40 = 1). Target 0 = the game's own 30
import os
from nso_asm import ADRP
# XC2_PATCHES (bisecting aid): stub, wind, dr = the three sites; no1 = leave out the [main+0xb900d0]+0x78/+0x7c stores (always, see above); mini / offonly / nostore / no2 = stub variants used to find that
only = os.environ.get('XC2_PATCHES', 'stub,wind,dr,no1').split(',')

build = 'feee7afa8a1541bd67aed1a0061fbb57'
stub_words = [0xd10183ff, 0xa90007e0, 0xf9000be2, 0xd53b4200, 0xf9000fe0, 0xad0107e0, 0x3d8013e2, 0x90000002,
        0xbd404c41, 0x1e202028, 0x540004e0, 0xd53be040, 0xf9402041, 0xf9002040, 0xb40004e1, 0xcb010000,
        0x9e630000, 0xd53be001, 0x9e630021, 0x1e611800, 0x1e624000, 0x1e2e1002, 0x1e211842, 0x1e222000,
        0x5400004a, 0x1e204040, 0x1e222842, 0x1e222000, 0x5400004d, 0x1e204040, 0xbd003840, 0x90000000,
        0xf9406800, 0xb4000160, 0xb9407801, 0x52824de2, 0x72a75062, 0x6b02003f, 0x540000c3, 0x52a7e002,
        0x6b02003f, 0x54000068, 0xbd007800, 0xbd007c00, 0x90000000, 0xf9416400, 0xb40000e0, 0xbd008000,
        0x14000005, 0x52911120, 0x72a7a100, 0xb9003840, 0xf900205f, 0xf9400fe0, 0xd51b4200, 0xad4107e0,
        0x3dc013e2, 0xa94007e0, 0xf9400be2, 0x910183ff, 0x52843408, 0xd65f03c0]   # assembled with clang (the adrp words are placeholders); it saves and restores every register it uses: the game keeps values in them across this point

def bl(frm, to): return 0x94000000 | (((to - frm) >> 2) & 0x3ffffff)

def frame_step(ctx):
    here, emit, site, put, S = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    site(0x7009e4, '08348452'); site(0x748658, '681300b0064941bd'); site(0x6aaabc, '086940f900013fd6')
    start = here()
    if 'mini' in only:
        emit(0x52843408); emit(0xd65f03c0)
    elif 'offonly' in only:
        emit(ADRP(2, here(), S))
        for w in (0xb9404c41, 0x34000061, 0x52843408, 0xd65f03c0, 0x52911120, 0x72a7a100, 0xb9003840, 0xf900205f, 0x52843408, 0xd65f03c0): emit(w)
    else:
     for i, w in enumerate(stub_words):
         pc = here()
         if ('nostore' in only and w in (0xbd007800, 0xbd007c00, 0xbd008000)) or ('no1' in only and w in (0xbd007800, 0xbd007c00)) or ('no2' in only and w == 0xbd008000): emit(0xd503201f); continue
         emit(ADRP(2, pc, S) if i == 7 else ADRP(0, pc, 0xb90000) if i == 31 else ADRP(0, pc, 0xc23000) if i == 44 else w)
    if 'stub' in only: put(0x7009e4, [bl(0x7009e4, start)], 'frame time: the measured step instead of mov w8,#0x21a0 (the stub ends with it)')
    if 'wind' in only: put(0x748658, [ADRP(8, 0x748658, S), 0xbd403906], 'wind speed: the step (state +0x38)')
    if 'dr' in only: put(0x6aaabc, [ADRP(8, 0x6aaabc, S), 0xbd404900], 'dynamic resolution budget: state +0x48 (host) instead of the virtual call')

FRAME_STEP = {build: frame_step}
