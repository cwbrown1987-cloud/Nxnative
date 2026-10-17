#!/usr/bin/env python3
"""Differential check of the host's NVN texture layout (dm/gfx/nvn/nvn_tex.c) against the game's own NVN driver.

The driver in the game's sdk module is never executed by the host. Here its pure texture-builder functions run under unicorn:
TextureBuilderSet*, GetStorageSize / GetStorageAlignment, the layout routine they share, TextureInitialize and TextureGetViewOffset.
Compared per shape: storage size, alignment, block height / depth, per-level offsets and layer stride.

  nvn_layout_diff.py <ExeFS/sdk> sweep                 # ~390k synthetic shapes over every format class, target and layout flag
  nvn_layout_diff.py <ExeFS/sdk> census <census.txt>   # the shapes a game really created (host run with DM_NVN_TEXCENSUS=<census.txt>)

Needs: pip install unicorn lz4 capstone; cc. Driver tables are found by pattern, not by fixed addresses
(the name→index lookup, the default implementation table, the format table, the layout routine and the storage-kind call).
Not modelled by the host (reported, expected): SPARSE textures; compressible textures get their size rounded to the big-page size by the
driver's memory manager, which the emulation stubs (storage kind 0xfe = plain block-linear).
"""
import collections
import ctypes as C
import itertools
import multiprocessing as mp
import os
import struct
import subprocess
import sys
import tempfile

import capstone
import lz4.block
import unicorn as U
from unicorn import arm64_const as A

BASE, STUB, HEAP, STACK, DEV, RET = 0x10000000, 0x0f000000, 0x20000000, 0x30000000, 0x40000000, 0x0e000000
PAGE = 0x1000
HERE = os.path.dirname(os.path.abspath(__file__))


def up(x, a=PAGE):
    return (x + a - 1) & ~(a - 1)


# ---------- sdk image ----------

class Image:
    def __init__(self, path):
        d = open(path, 'rb').read()
        flags = struct.unpack_from('<I', d, 0xC)[0]
        segs = [struct.unpack_from('<III', d, 0x10 + i * 0x10) for i in range(3)]
        csz = struct.unpack_from('<III', d, 0x60)
        img = bytearray(segs[2][1] + segs[2][2] + struct.unpack_from('<I', d, 0x3C)[0])
        for i, (fo, mo, sz) in enumerate(segs):
            raw = d[fo:fo + csz[i]]
            img[mo:mo + sz] = lz4.block.decompress(raw, uncompressed_size=sz) if flags >> i & 1 else raw
        self.text_end, self.raw = segs[0][1] + segs[0][2], bytes(img)
        mod0 = struct.unpack_from('<I', img, 4)[0]
        dyn = mod0 + struct.unpack_from('<i', img, mod0 + 4)[0]
        tags = {}
        for i in range(4096):
            t, v = struct.unpack_from('<qQ', img, dyn + i * 16)
            if t == 0:
                break
            tags.setdefault(t, v)
        symtab, strtab = tags[6], tags[5]
        syms = []
        for i in range((strtab - symtab) // 24):
            name, _, _, shndx, value, _ = struct.unpack_from('<IBBHQQ', img, symtab + i * 24)
            syms.append((bytes(img[strtab + name:img.index(b'\0', strtab + name)]).decode('latin1'), shndx, value))
        self.rel, self.imports = {}, {}   # RELATIVE: slot → target offset; imports: slot → symbol name
        for tag_off, tag_sz in ((7, 8), (23, 2)):
            for k in range(tags.get(tag_sz, 0) // 24):
                off, info, add = struct.unpack_from('<QQq', img, tags[tag_off] + k * 24)
                typ, name = info & 0xFFFFFFFF, syms[info >> 32]
                if typ == 1027:
                    self.rel[off] = add
                elif typ in (1025, 1026, 257):
                    if name[1]:
                        self.rel[off] = name[2] + add
                    else:
                        self.imports[off] = name[0]
        if 36 in tags:   # DT_RELR (newer SDKs): packed relative relocations, addend stored in place
            where = 0
            for k in range(tags[35] // 8):
                e = struct.unpack_from('<Q', img, tags[36] + 8 * k)[0]
                if not e & 1:
                    self.rel[e] = struct.unpack_from('<Q', img, e)[0]
                    where = e + 8
                else:
                    for bit in range(63):
                        if e >> (bit + 1) & 1:
                            self.rel[where + 8 * bit] = struct.unpack_from('<Q', img, where + 8 * bit)[0]
                    where += 63 * 8
        self.cs = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
        self.cs.detail = True

    def u32(self, a):
        return struct.unpack_from('<I', self.raw, a)[0]

    def insns(self, a, n):
        return list(self.cs.disasm(self.raw[a:a + 4 * n], a))

    def cstr(self, a):
        return self.raw[a:self.raw.index(b'\0', a)].decode('latin1')


def adrp_target(ins):
    return ins.operands[1].imm


def find_tables(im):
    """Name table of the NVN name→index lookup, the default implementation table, and the driver routines used below."""
    # Lookup: ldrb w8,[x0]; cmp w8,#'n'; ... cmp w8,#'v' ... cmp w8,#'n'; then 'mov wN,#count-1' and two adrp+add (offset table, string pool)
    w = memoryview(im.raw)[:im.text_end].cast('I')
    lookup = None
    for i in range(len(w) - 16):
        if w[i] & 0xFFFFFC1F == 0x7101B81F and (w[i + 3] & 0xFFFFFC1F) == 0x7101D81F:   # cmp wN,#0x6e ... cmp wN,#0x76
            lookup = i * 4 - 8
            break
    assert lookup is not None, 'NVN name lookup not found'
    body = im.insns(lookup, 40)
    count, adds = None, []
    for k, ins in enumerate(body):
        if ins.mnemonic == 'mov' and count is None and ins.op_str.startswith('w') and '#0x' in ins.op_str and int(ins.op_str.split('#')[1], 16) > 100:
            count = int(ins.op_str.split('#')[1], 16) + 1
        if ins.mnemonic == 'adrp':
            nxt = next(x for x in body[k + 1:] if x.mnemonic == 'add' and x.op_str.split(',')[1].strip() == ins.op_str.split(',')[0])
            adds.append(adrp_target(ins) + nxt.operands[2].imm)
    offs_tab, pool = adds[0], adds[1]
    names = [im.cstr(pool + im.u32(offs_tab + 4 * i)) for i in range(count)]
    assert names == sorted(names), 'NVN name table not sorted'
    # Default implementation table: `count` relocated .text pointers in name order, recognised by three trivial accessors
    idx = {n: i for i, n in enumerate(names)}

    def code(a, n=2):
        return [x.mnemonic + ' ' + x.op_str for x in im.insns(a, n)]
    impl = None
    for base in sorted(im.rel):
        get = [im.rel.get(base + 8 * idx[n], 0) for n in ('TextureBuilderSetDevice', 'TextureBuilderGetDevice', 'TextureBuilderSetSize3D')]
        if base % 8 or not all(0 < a < im.text_end for a in get):
            continue
        if code(get[0]) != ['str x1, [x0, #8]', 'ret '] or code(get[1]) != ['ldr x0, [x0, #8]', 'ret '] or not code(get[2], 1)[0].startswith('stp w1, w2, [x0'):
            continue
        if all(0 < im.rel.get(base + 8 * i, 0) < im.text_end for i in range(count)):
            impl = {n: im.rel[base + 8 * i] for i, n in enumerate(names)}
            break
    assert impl, 'NVN implementation table not found'
    # GetStorageSize: first bl = layout routine; the format table is adrp+ldr of a relocated pointer (older SDKs) or adrp+add (newer)
    gss = im.insns(impl['TextureBuilderGetStorageSize'], 40)
    layout = next(x.operands[0].imm for x in gss if x.mnemonic == 'bl')
    fmt_tab = None
    for k, ins in enumerate(gss):
        if ins.mnemonic == 'adrp':
            reg = ins.op_str.split(',')[0]
            use = next(x for x in gss[k + 1:] if x.op_str.split(',')[0] == reg or reg in x.op_str.split(',')[1])
            fmt_tab = im.rel[adrp_target(ins) + use.operands[1].mem.disp] if use.mnemonic == 'ldr' else adrp_target(ins) + use.operands[2].imm
            break
    # Storage kind: the call whose argument is the device's memory manager ('add x0, xN, #member; bl', member well inside the device object),
    # in the layout routine or one call deeper (newer SDKs moved it into the storage-class helper)
    def kind_call(insns):   # 'add x0, xN, #m; bl f' (v0) or 'add xT, xN, #m; mov x0, xT; b f' (tail call, newer)
        for k in range(len(insns) - 2):
            a = insns[k]
            if a.mnemonic != 'add' or len(a.operands) < 3 or a.operands[2].type != capstone.arm64.ARM64_OP_IMM or a.operands[2].imm < 0x100:
                continue
            dst, nxt = a.op_str.split(',')[0], insns[k + 1]
            if dst == 'x0' and nxt.mnemonic in ('bl', 'b'):
                return nxt.operands[0].imm
            if nxt.mnemonic == 'mov' and nxt.op_str == 'x0, ' + dst and insns[k + 2].mnemonic in ('bl', 'b'):
                return insns[k + 2].operands[0].imm
        return None
    lay = im.insns(layout, 400)
    kind = kind_call(lay)
    for callee in (x.operands[0].imm for x in lay if x.mnemonic == 'bl' and kind is None):
        kind = kind_call(im.insns(callee, 120))
        if kind is not None:
            break
    assert kind is not None, 'storage-kind call not found'
    return dict(names=names, impl=impl, layout=layout, fmt_tab=fmt_tab, kind=kind)


# ---------- emulated driver ----------

class Driver:
    def __init__(self, sdk):
        im = self.im = Image(sdk)
        self.t = find_tables(im)
        img = bytearray(im.raw)
        self.stub_names = sorted(set(im.imports.values()))
        stub_of = {n: STUB + 16 * i for i, n in enumerate(self.stub_names)}
        for off, add in im.rel.items():
            struct.pack_into('<Q', img, off, BASE + add)
        for off, name in im.imports.items():
            struct.pack_into('<Q', img, off, stub_of[name])
        uc = self.uc = U.Uc(U.UC_ARCH_ARM64, U.UC_MODE_ARM)
        uc.mem_map(BASE, up(len(img)))
        uc.mem_write(BASE, bytes(img))
        nstub = max(1, len(self.stub_names))
        uc.mem_map(STUB, up(16 * nstub))
        uc.mem_write(STUB, b'\xc0\x03\x5f\xd6' * 4 * nstub)
        for base, size in ((RET, PAGE), (HEAP, 0x1000000), (STACK, 0x100000), (DEV, 0x10000)):
            uc.mem_map(base, size)
        uc.hook_add(U.UC_HOOK_CODE, self._stub, begin=STUB, end=STUB + 16 * nstub)
        uc.hook_add(U.UC_HOOK_CODE, self._kind, begin=BASE + self.t['kind'], end=BASE + self.t['kind'])
        self.heap = HEAP
        self.pool = self.alloc(0x100)
        uc.mem_write(self.pool + 0x10, struct.pack('<H', 0x80))           # flags: COMPRESSIBLE (compressible textures refuse other pools)
        uc.mem_write(self.pool + 0x20, struct.pack('<Q', 0x100000000))    # GPU address (TextureInitialize fails on 0)
        self.view = self.alloc(0x28)
        self.mark = self.heap

    def _stub(self, uc, addr, size, _):
        name = self.stub_names[(addr - STUB) // 16]
        x = [uc.reg_read(getattr(A, 'UC_ARM64_REG_X%d' % i)) for i in range(3)]
        if name in ('memcpy', 'memmove') and x[2]:
            uc.mem_write(x[0], bytes(uc.mem_read(x[1], x[2])))
        elif name == 'memset' and x[2]:
            uc.mem_write(x[0], bytes([x[1] & 0xFF]) * x[2])
        else:
            uc.reg_write(A.UC_ARM64_REG_X0, 0)

    def _kind(self, uc, addr, size, _):
        uc.reg_write(A.UC_ARM64_REG_X0, 0xFE)
        uc.reg_write(A.UC_ARM64_REG_PC, uc.reg_read(A.UC_ARM64_REG_LR))

    def alloc(self, n, data=None):
        a, self.heap = self.heap, self.heap + up(n, 16)
        self.uc.mem_write(a, data if data is not None else bytes(n))
        return a

    def call(self, fn, *args):
        fn = self.t['impl'][fn] if isinstance(fn, str) else fn
        for i, v in enumerate(args):
            self.uc.reg_write(getattr(A, 'UC_ARM64_REG_X%d' % i), v & 0xFFFFFFFFFFFFFFFF)
        self.uc.reg_write(A.UC_ARM64_REG_SP, STACK + 0xFF000)
        self.uc.reg_write(A.UC_ARM64_REG_LR, RET)
        self.uc.emu_start(BASE + fn, RET, count=2000000)
        return self.uc.reg_read(A.UC_ARM64_REG_X0)

    def fmt(self, f):
        e = self.im.raw[self.t['fmt_tab'] + 0x30 * f:self.t['fmt_tab'] + 0x30 * f + 0x30]
        return e[0] & 1, e[0x10], e[8], e[9]   # usable, bytes per block, block width, block height

    def measure(self, target, fmt, w, h, d, levels, flags, samples, layout, stride):
        self.heap = self.mark
        b = self.alloc(0x80)
        self.call('TextureBuilderSetDefaults', b)
        for fn, *a in (('TextureBuilderSetDevice', DEV), ('TextureBuilderSetTarget', target), ('TextureBuilderSetFormat', fmt),
                       ('TextureBuilderSetSize3D', w, h, d), ('TextureBuilderSetLevels', levels), ('TextureBuilderSetFlags', flags)):
            self.call(fn, b, *a)
        if samples:
            self.call('TextureBuilderSetSamples', b, samples)
        if stride:
            self.call('TextureBuilderSetStride', b, stride)
        if layout is not None:
            self.call('TextureBuilderSetPackagedTextureLayout', b, self.alloc(8, bytes([layout, 0, 0, 0, 0, 0, 0, 0])))
        r = dict(size=self.call('TextureBuilderGetStorageSize', b), align=self.call('TextureBuilderGetStorageAlignment', b))
        desc = self.alloc(0x40)
        self.call(self.t['layout'], desc, b)
        r['blk'] = tuple(bytes(self.uc.mem_read(desc + 0x28, 3)))   # block width, height, depth (log2 GOBs)
        r['offs'] = r['layer'] = None
        try:   # compressible depth formats fault in Initialize's compression-tag setup (needs the real memory manager): size-only check
            self.call('TextureBuilderSetStorage', b, self.pool, 0)
            t = self.alloc(0xC0)
            if self.call('TextureInitialize', t, b) & 0xFF:
                r['offs'] = [self.view_offset(t, level=k) for k in range(levels)]
                if target in (3, 4, 6, 8, 9):
                    r['layer'] = self.view_offset(t, layer=1)
        except U.UcError:
            pass
        return r

    def view_offset(self, t, level=None, layer=None):
        self.call('TextureViewSetDefaults', self.view)
        if level is not None:
            self.call('TextureViewSetLevels', self.view, level, 1)
        if layer is not None:
            self.call('TextureViewSetLayers', self.view, layer, 1)
        return self.call('TextureGetViewOffset', t, self.view)


# ---------- host (nvn_tex.c) ----------

class Desc(C.Structure):
    _fields_ = [('target', C.c_int), ('format', C.c_int), ('flags', C.c_int), ('samples', C.c_int), ('width', C.c_uint32),
                ('height', C.c_uint32), ('depth', C.c_uint32), ('levels', C.c_uint32), ('stride', C.c_uint32), ('pkg_layout', C.c_int)]


class Layout(C.Structure):
    _fields_ = [('size', C.c_uint64), ('layer_size', C.c_uint64), ('align', C.c_uint32), ('layers', C.c_uint32), ('bpb', C.c_uint32),
                ('tileH', C.c_uint), ('tileD', C.c_uint)]


def host_lib():
    out = os.path.join(tempfile.gettempdir(), 'nvn_tex_%d.dylib' % os.getpid())
    subprocess.run(['cc', '-O1', '-shared', '-o', out, os.path.join(HERE, '..', 'gfx', 'nvn', 'nvn_tex.c')], check=True)
    lib = C.CDLL(out)
    lib.nvn_tex_level_offset.restype = C.c_uint64
    return lib


# ---------- comparison ----------

DRV = LIB = None


def init(sdk, lib_path):
    global DRV, LIB
    DRV = Driver(sdk)
    LIB = C.CDLL(lib_path)
    LIB.nvn_tex_level_offset.restype = C.c_uint64


def compare(cfg):
    target, fmt, w, h, d, levels, flags, samples, layout, stride = cfg
    try:
        o = DRV.measure(*cfg)
    except U.UcError as ex:
        return cfg, [('emulation error', repr(ex), None)]
    ds = Desc(target, fmt, flags, samples, w, h, d, levels, stride, 0x100 | layout if layout is not None else 0)
    L = Layout()
    LIB.nvn_tex_layout(C.byref(ds), C.byref(L))
    diffs = []
    if o['size'] != L.size:
        diffs.append(('size', o['size'], L.size))
    if o['align'] != L.align:
        diffs.append(('alignment', o['align'], L.align))
    if o['size'] and not flags & 0x50 and (o['blk'][1], o['blk'][2] if target == 2 else 0) != (L.tileH, L.tileD):
        diffs.append(('block height/depth', o['blk'][1:], (L.tileH, L.tileD)))
    if o['size'] and o['offs'] is not None:
        host = [LIB.nvn_tex_level_offset(C.byref(ds), k) for k in range(levels)]
        if o['offs'] != host:
            diffs.append(('level offsets', o['offs'], host))
    if o['size'] and o['layer'] is not None and o['layer'] != L.layer_size:
        diffs.append(('layer stride', o['layer'], L.layer_size))
    return cfg, diffs


def sweep_cfgs(drv):
    reps = {}
    for f in range(0x9D):
        ok, bpb, bw, bh = drv.fmt(f)
        if ok and bpb:
            reps.setdefault((bpb, bw, bh), f)
    S = [1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 24, 31, 32, 33, 48, 63, 64, 65, 78, 100, 127, 128, 129, 255, 256, 257, 511, 512, 513,
         720, 1000, 1024, 1080, 1920, 2048, 4096]
    S3 = [1, 2, 3, 4, 5, 8, 9, 16, 17, 32, 33, 64, 65, 128]

    def full(*dims):
        return max(1, max(dims).bit_length())
    c = []
    for (bpb, bw, bh), f in reps.items():
        for w, h in itertools.product(S, S):
            c += [(1, f, w, h, 1, 1, 0, 0, None, 0), (1, f, w, h, 1, full(w, h), 0, 0, None, 0)]
        for w in S:
            c += [(0, f, w, 1, 1, full(w), 0, 0, None, 0), (3, f, w, 3, 1, full(w), 0, 0, None, 0)]
        c += [(2, f, w, h, d, full(w, h, d), 0, 0, None, 0) for w, h, d in itertools.product(S3, S3, S3)]
        c += [(4, f, w, h, n, full(w, h), 0, 0, None, 0) for (w, h), n in itertools.product(itertools.product(S[::3], S[::3]), (2, 3, 6, 7, 12))]
        for s, n in itertools.product(S[::2], (6, 12, 18)):
            c += [(8, f, s, s, 1, full(s), 0, 0, None, 0), (9, f, s, s, n, full(s), 0, 0, None, 0)]
        for fl, al in ((0x10, 32), (0x40, 128)):   # LINEAR / LINEAR_RENDER_TARGET, minimal and wider pitch
            for w, h in itertools.product(S[::2], S[::2]):
                p = ((w + bw - 1) // bw * bpb + al - 1) // al * al
                c += [(1, f, w, h, 1, 1, fl, 0, None, p), (1, f, w, h, 1, 1, fl, 0, None, p + al)]
        for fl in (0x8, 0x20, 0x200, 0x4, 0x1):    # COMPRESSIBLE, SPARSE, MINIMAL_LAYOUT, IMAGE, DISPLAY
            c += [(1, f, w, h, 1, full(w, h), fl, 0, None, 0) for w, h in itertools.product(S[::2], S[::2])]
            c += [(2, f, w, h, d, full(w, h, d), fl, 0, None, 0) for w, h, d in itertools.product(S3[::2], S3[::2], S3[::2])]
        for w, h in itertools.product(S[::3], S):   # MINIMAL_LAYOUT with partial mip chains, arrays, cubes
            c += [(1, f, w, h, 1, min(lv, full(w, h)), 0x200, 0, None, 0) for lv in (1, 2, 3)] + [(4, f, w, h, 3, full(w, h), 0x200, 0, None, 0)]
        for s in S[::2]:
            c += [(8, f, s, s, 1, full(s), 0x200, 0, None, 0), (9, f, s, s, 12, full(s), 0x200, 0, None, 0)]
        c += [(2, f, w, h, d, min(2, full(w, h, d)), 0x200, 0, None, 0) for w, h, d in itertools.product(S3[::3], S3, S3)]
        for l0 in [x | y << 4 for x in range(6) for y in range(3)]:   # packaged layouts: block height 0..5, block depth 0..2
            c += [(1, f, w, h, 1, full(w, h), 0, 0, l0, 0) for w, h in itertools.product(S[::4], S[::4])]
            c += [(2, f, w, h, d, full(w, h, d), 0, 0, l0, 0) for w, h, d in itertools.product(S3[::3], S3[::3], S3[::3])]
    for f in (0x25, 0x2B, 0x33, 0x37):   # multisample
        for s in (2, 4, 8):
            c += [(t, f, w, h, n, 1, 0, s, None, 0) for w, h in itertools.product(S[::3], S[::3]) for t, n in ((5, 1), (6, 3))]
    return reps, c


def census_cfgs(path):
    c = []
    for ln in open(path):
        p = ln.split()
        if len(p) < 10:
            continue
        lay = None if p[9].startswith('-') else int(p[9][:2], 16)
        c.append((int(p[0]), int(p[1], 16), int(p[4]), int(p[5]), int(p[6]), int(p[7]), int(p[2], 16), int(p[3]), lay, int(p[8])))
    return c


def main():
    if len(sys.argv) < 3 or sys.argv[2] not in ('sweep', 'census') or (sys.argv[2] == 'census' and len(sys.argv) < 4):
        sys.exit(__doc__)
    sdk = sys.argv[1]
    drv = Driver(sdk)
    t = drv.t
    print('driver: %d API names; layout routine %#x, format table %#x, storage-kind call %#x' % (len(t['names']), t['layout'], t['fmt_tab'], t['kind']))
    lib = host_lib()
    if sys.argv[2] == 'sweep':
        reps, cfgs = sweep_cfgs(drv)
        bad = []
        for f in range(0x9D):
            ok, bpb, bw, bh = drv.fmt(f)
            hbw, hbh = C.c_int(), C.c_int()
            hb = lib.nvn_fmt_bpb(f, C.byref(hbw), C.byref(hbh))
            if ok and (bpb, bw, bh) != (hb, hbw.value, hbh.value):
                bad.append('%#x driver %s host %s' % (f, (bpb, bw, bh), (hb, hbw.value, hbh.value)))
        print('formats: %d block classes; format-table mismatches: %s' % (len(reps), bad or 'none'))
    else:
        cfgs = census_cfgs(sys.argv[3])
    print('shapes:', len(cfgs))
    kinds, samples = collections.Counter(), collections.defaultdict(list)
    with mp.Pool(os.cpu_count(), initializer=init, initargs=(sdk, lib._name)) as pool:
        for cfg, diffs in pool.imap_unordered(compare, cfgs, chunksize=64):
            for k, a, b in diffs:
                tag = 'packaged' if cfg[8] is not None else 'flags %#x' % cfg[6] if cfg[6] else 'samples %d' % cfg[7] if cfg[7] else 'automatic'
                key = (k, 'target %d' % cfg[0], tag)
                kinds[key] += 1
                samples[key].append((cfg, a, b))
    os.unlink(lib._name)
    if not kinds:
        print('all shapes match the driver')
    for key, n in sorted(kinds.items()):
        print('%s: %d' % (' / '.join(key), n))
        for cfg, a, b in samples[key][:3]:
            print('    target %d fmt %#x %dx%dx%d levels %d flags %#x samples %d layout %s stride %d: driver %s host %s' % (*cfg[:8], cfg[8], cfg[9], a, b))
    sys.exit(1 if any(k[2] != 'flags 0x20' for k in kinds) else 0)   # SPARSE (0x20) is the known, unmodelled gap


if __name__ == '__main__':
    main()
