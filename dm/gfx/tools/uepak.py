#!/usr/bin/env python3
# Unreal Engine game files for the shader tools: pak files (version 11, UE 4.26 and later; Octopath Traveler 0 is UE5), shader code archives (.ushaderbytecode version 2) and the job files the Mac host decodes Oodle with
# (DM_OODLE_JOB, dm/host/hle_oodle.c). Octopath Traveler 0 keeps everything in one pak, Octopath_Traveler0/Content/Paks/pakchunk0-Switch.pak (1.5 GB, 159,757 files): its index is AES-256 encrypted,
# its files are stored or Oodle-compressed in blocks. Its two shader code archives are stored, but every shader inside is Oodle-compressed (Mermaid, block header 8C 0A), which no decoder in this
# repository can undo, so the game's own OodleLZ_Decompress decodes them in the Mac host (the NSP script's decode_ue_shaders, for any game with Unreal paks).
# The AES key is in main (Unreal embeds it): the 32-byte window of main's read-only or data segment that decrypts the index start to its mount point ("../../../"; Octopath Traveler 0: one window of
#   116,287 tried). It is only kept in memory, never printed or written.
# Pak footer (version 11, the last 0xdd bytes): encryption key GUID (16), encrypted index flag (u8), magic 0x5A6F12E1, version (u32), index offset (u64), index size (u64), index SHA-1 (20),
#   5 compression method names (32 bytes each).
# The pak UE5's IoStore path writes (FINAL FANTASY RESONANCE, FFRS-Switch.pak, 2.9 GB, 2,363 files) keeps its magic 0xcc from the end instead of 0xc8 (the key GUID and the encrypted flag take
#   17 bytes in front of it there and 21 in a usual pak), so the magic is found by scanning backwards from the end; the fields after the magic are the same, and so is the index.
# Index: mount point (FString), entry count (i32), path hash seed (u64), path hash index (i32 flag, then u64 offset, u64 size, SHA-1), full directory index (the same, encrypted like the index),
#   encoded entries (i32 size + bytes), the count of unencoded entries (0 here). Directory index: i32 count, then per directory its name (FString) and its files (i32 count, then name + i32 offset into
#   the encoded entries). FString: i32 length with the NUL, UTF-8; a negative length is UTF-16.
# Encoded entry: u32 bits (0-5 compression block size >> 11, 0x3f = a u32 follows; 6-21 block count; 22 encrypted; 23-28 compression method, 1-based; 29 stored size fits 32 bits; 30 raw size fits
#   32 bits; 31 offset fits 32 bits), then offset, raw size, stored size (compressed entries only) and, for several blocks or an encrypted one, each block's u32 stored size. The data starts after
#   the FPakEntry the pak repeats in front of it (53 bytes, + 4 + 16 per block when compressed); blocks follow each other, 16-aligned when encrypted.
# Older paks (version 4, UE 4.18: DRAGON QUEST XI S, pakchunk0-Switch.pak 6.6 GB / 264,844 files and pakchunk1-Switch.pak 7.2 GB / 147,824 files, the update's *_0_P.pak beside them) keep the
#   legacy layout. Footer (the last 0x2d bytes): encrypted index flag (u8), magic, version, index offset, index size, SHA-1. Index: mount point, entry count, then per file its name (relative to the
#   mount point) and its FPakEntry: offset, stored size, raw size (i64 each), compression flags (i32), SHA-1 (20), for a compressed file the block count (i32) and each block's start and end
#   (i64, from the file start before version 5, from the entry after), the encrypted flag (u8) and the compression block size (u32). The FPakEntry is repeated in front of the data.
#   The compression flags are no names: 1 zlib, 2 gzip, 4 custom; DRAGON QUEST XI S's engine uses 3, which is LZ5 2.0 (main exports LZ5_*; every block starts with its level, 0x2d = 45), and only the
#   game's own decoder reads it (hle_oodle.c, through a decode function given to Pak.read).
# Shader code archive (version 2): shader map hashes (20 bytes each), shader hashes (20 each), shader map entries {u32 first index, u32 shader count, u32 first preload, u32 preload count}, shader
#   entries {u64 offset, u32 size, u32 raw size, u8 frequency} (17 bytes, packed), preload entries (16 each), shader indices (u32): each array is a u32 count and its elements; the code follows,
#   offsets relative to its start. A shader whose size differs from its raw size is compressed.
# Usage: uepak.py list <pak> [<main NSO>] <out tsv>                every file in the pak: path, raw size, stored size, compression, encrypted, blocks (the NSO is
#                                                                 only read when the index is encrypted)
#        uepak.py extract <pak> [<main NSO>] <path> <out file>     one file of the pak (a file only the game's own decoder can read is written as it is stored,
#                                                                 with its compressed blocks in <out file>.oodle.job)
#        uepak.py job <RomFS> <main NSO> <work dir>                     the shader code archives of every pak, and an Oodle job of their compressed shaders
#        uepak.py finish <work dir> <out dir>                           after the host has run the job: the archives with every shader decoded
import ctypes, json, mmap, os, re, struct, sys

PAK_MAGIC, ARCHIVE_VERSION = 0x5A6F12E1, 2
JOB_MAGIC, OUT_MAGIC = 0x4a4f4d44, 0x524f4d44   # "DMOJ", "DMOR" (hle_oodle.c)
FREQ = {0: 'vs', 1: 'hs', 2: 'ds', 3: 'ps', 4: 'gs', 5: 'cs'}   # EShaderFrequency (the archive's frequency census: 0 vertex, 3 pixel, 5 compute)

_cc = None
def aes_decrypt(key, data):
    """AES-256 ECB decryption through CommonCrypto (every Mac has it; no Python package needed)"""
    global _cc
    if _cc is None:
        _cc = ctypes.CDLL('/usr/lib/libSystem.B.dylib').CCCrypt
        _cc.restype = ctypes.c_int32
        _cc.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    out = ctypes.create_string_buffer(len(data)); moved = ctypes.c_size_t()
    if _cc(1, 0, 2, key, len(key), None, data, len(data), out, len(data), ctypes.byref(moved)): raise ValueError('CCCrypt failed')   # decrypt, AES, ECB
    return out.raw[:moved.value]

def nso_image(path):
    """A decompressed NSO image and its (read-only start, data end)"""
    import lz4.block
    d = open(path, 'rb').read()
    flags = struct.unpack_from('<I', d, 0xc)[0]; segs = [struct.unpack_from('<III', d, 0x10 + i * 0x10) for i in range(3)]; csz = struct.unpack_from('<III', d, 0x60)
    img = bytearray(segs[2][1] + segs[2][2])
    for i, (fo, mo, sz) in enumerate(segs):
        raw = d[fo:fo + csz[i]]
        img[mo:mo + sz] = lz4.block.decompress(raw, uncompressed_size=sz) if flags >> i & 1 else raw
    return bytes(img), segs[1][1], segs[2][1] + segs[2][2]

class R:
    def __init__(self, b, o=0): self.b, self.o = b, o
    def take(self, fmt):
        v = struct.unpack_from(fmt, self.b, self.o); self.o += struct.calcsize(fmt); return v if len(v) > 1 else v[0]
    def raw(self, n): v = self.b[self.o:self.o + n]; self.o += n; return v
    def fstr(self):
        n = self.take('<i')
        if n < 0: return self.raw(-2 * n).decode('utf-16-le')[:-1]
        return self.raw(n)[:-1].decode('utf-8', 'replace') if n else ''

LEGACY = (4,)   # legacy pak versions read (the per-file index); 11 has the encoded one
LEGACY_METHODS = {1: 'Zlib', 2: 'Gzip', 3: 'LZ5', 4: 'Custom'}   # compression flags of a legacy pak (3: DRAGON QUEST XI S's engine, see the header)

def pak_version(f):
    """The version of a pak: a legacy footer is the last 0x2d bytes (magic 0x2c from the end); version 11's is 0xdd bytes, the magic 0xc8 from the end.
    The magic is looked for where it usually is and then by scanning backwards from the end (a pak written by UE5's IoStore path keeps it 0xcc from the end)"""
    return find_footer(f)[1]

def find_footer(f):
    """(offset of the footer's start, version): a version 11 pak's footer is the last 0xdd bytes with its magic 0xc8
    from the end, but a pak written by UE5's IoStore path (FINAL FANTASY RESONANCE) has the footer before a tail of
    padding, so the magic is found by scanning backwards from the end. The footer's start is the magic's offset
    minus 0x15 (the fields before the magic)."""
    f.seek(0, 2); n = f.tell()
    for back in (0xc8, 0x2c):   # the usual places
        if n < back + 8: continue   # the file is too small for a footer there
        f.seek(-back, 2); m, ver = struct.unpack('<II', f.read(8))
        # a version 11 footer's magic sits 0x15 bytes into it, a legacy footer's one byte into it
        if m == PAK_MAGIC: return (n - back - 0x15) if ver == 11 else (n - back - 1), ver
    # scan the last 64 KB for the magic
    window = min(n, 1 << 16)
    f.seek(n - window); buf = f.read(window)
    i = buf.rfind(struct.pack('<I', PAK_MAGIC))
    if i < 0: raise ValueError('no pak footer')
    at = n - window + i
    ver, = struct.unpack_from('<I', buf, i + 4)
    return (at - 0x15) if ver == 11 else at - 1, ver

def footer(f):
    """(encrypted index, index offset, index size, compression method names by number from 1, version)"""
    at, ver = find_footer(f)
    if ver in LEGACY:
        f.seek(at); ft = f.read(0x2d); ioff, isz = struct.unpack_from('<QQ', ft, 9)
        return ft[0], ioff, isz, [LEGACY_METHODS.get(i, f'flags {i}') for i in range(1, 8)], ver
    if ver != 11: raise ValueError(f'pak version {ver}, only {", ".join(map(str, LEGACY))} and 11 are read')
    f.seek(at); ft = f.read(0xdd); k = 0xdd - 0xc8
    ioff, isz = struct.unpack_from('<QQ', ft, k + 8)
    methods = [ft[k + 44 + 32 * i:k + 76 + 32 * i].rstrip(b'\0').decode('latin1') for i in range(5)]
    return ft[k - 1], ioff, isz, methods, ver

def find_key(img, lo, hi, pak):
    """The AES key among main's 32-byte windows (read-only and data segments, 4-aligned, at least 20 distinct bytes): the one that decrypts the index start to a short mount point"""
    with open(pak, 'rb') as f:
        _, ioff, _, _, _ = footer(f); f.seek(ioff); blk = f.read(16)
    for a in range(lo, hi - 32, 4):
        w = img[a:a + 32]
        if len(set(w)) < 20: continue
        d = aes_decrypt(w, blk)
        if 0 < struct.unpack_from('<i', d)[0] < 512 and d[4:7] == b'../': return w
    return None

class Pak:
    def __init__(self, path, key=None):
        self.path, self.key = path, key; self.f = open(path, 'rb')
        enc, ioff, isz, self.methods, self.version = footer(self.f)
        if enc and not key: raise ValueError(f'{path}: the index is encrypted and no key was given')
        r = R(self.read_at(ioff, isz, enc))
        self.mount = r.fstr(); self.count = r.take('<i')
        if self.version in LEGACY:   # one FPakEntry per file, kept as parsed
            self.files = {}
            for _ in range(self.count):
                name = r.fstr(); off, size, raw, meth = r.take('<qqqi'); r.raw(20)
                blocks = [r.take('<qq') for _ in range(r.take('<i'))] if meth else []
                e, bsz = r.take('<BI'); head = 53 + (4 + 16 * len(blocks) if meth else 0)
                if self.version < 5: blocks = [(s - off, t - s) for s, t in blocks]
                else: blocks = [(s, t - s) for s, t in blocks]
                self.files[name] = dict(off=off, raw=raw, size=size, method=self.methods[meth - 1] if meth else '', encrypted=e, block_size=bsz, blocks=blocks or [(head, size)])
            return
        r.take('<Q')
        if r.take('<i'): r.take('<QQ'); r.raw(20)   # path hash index (not needed with the full directory index)
        if not r.take('<i'): raise ValueError(f'{path}: no full directory index')
        doff, dsz = r.take('<QQ'); r.raw(20)
        self.enc = r.raw(r.take('<i'))
        if r.take('<i'): raise ValueError(f'{path}: unencoded entries are not read')
        d = R(self.read_at(doff, dsz, enc)); self.files = {}
        for _ in range(d.take('<i')):
            dn = d.fstr()
            for _ in range(d.take('<i')): fn = d.fstr(); self.files[(dn + fn).lstrip('/')] = d.take('<i')
    def read_at(self, off, n, enc):
        self.f.seek(off); b = self.f.read((n + 15) & ~15 if enc else n)
        return aes_decrypt(self.key, b)[:n] if enc else b
    def entry(self, path):
        if self.version in LEGACY: return self.files[path]
        r = R(self.enc, self.files[path]); v = r.take('<I')
        bsz = (v & 0x3f) << 11
        if v & 0x3f == 0x3f: bsz = r.take('<I')
        nblk, enc, meth = v >> 6 & 0xffff, v >> 22 & 1, v >> 23 & 0x3f
        off = r.take('<I' if v >> 31 & 1 else '<Q'); raw = r.take('<I' if v >> 30 & 1 else '<Q')
        size = r.take('<I' if v >> 29 & 1 else '<Q') if meth else raw
        cur, blocks = 53 + (4 + 16 * nblk if meth else 0), []
        if nblk == 1 and not enc: blocks = [(cur, size)]
        else:
            for _ in range(nblk): s = r.take('<I'); blocks.append((cur, s)); cur += (s + 15) & ~15 if enc else s
        return dict(off=off, raw=raw, size=size, method=self.methods[meth - 1] if meth else '', encrypted=enc, block_size=bsz, blocks=blocks)
    def read(self, path, decode=None):
        """A file's bytes. A compressed one needs decode(block bytes, raw length) → bytes, block by block (each block holds block_size raw bytes, the last one the rest):
        the game's own decoder in the Mac host (shader_split.py oodle); Octopath Traveler 0's archives go through the Oodle job instead.
        A pak that keeps a file in one block leaves the block size at 0 (that block then holds the whole file)"""
        e = self.entry(path)
        if not e['method']: return self.read_at(e['off'] + 53, e['size'], e['encrypted'])
        if not decode: raise ValueError(f'{path} is {e["method"]}-compressed in the pak')
        out, left = [], e['raw']
        for s, n in e['blocks']:
            k = min(left, e['block_size']) if e['block_size'] else left
            out.append(decode(self.read_at(e['off'] + s, n, e['encrypted']), k)); left -= k
        return b''.join(out)
    def stored(self, path):
        """A file's bytes as they are stored in the pak (the compressed blocks one after the other, or the file itself when it is not compressed)"""
        e = self.entry(path)
        if not e['method']: return self.read_at(e['off'] + 53, e['size'], e['encrypted'])
        return b''.join(self.read_at(e['off'] + s, n, e['encrypted']) for s, n in e['blocks'])

def archive(b):
    """A shader code archive's tables: {'maps': [(first index, count)], 'shaders': [(offset, size, raw size, frequency)], 'indices': [...], 'code': start of the code}"""
    r = R(b)
    if r.take('<I') != ARCHIVE_VERSION: raise ValueError('not a version 2 shader code archive')
    nmap = r.take('<I'); r.raw(20 * nmap); nsh = r.take('<I'); r.raw(20 * nsh)
    maps = [r.take('<IIII')[:2] for _ in range(r.take('<I'))]
    shaders = [r.take('<QIIB') for _ in range(r.take('<I'))]
    r.raw(16 * r.take('<I'))
    n = r.take('<I'); indices = list(struct.unpack_from(f'<{n}I', b, r.o)); r.o += 4 * n
    return dict(maps=maps, shaders=shaders, indices=indices, code=r.o)

def decoded_archive(b, raws):
    """The archive with every shader replaced by its decoded bytes (raws, in entry order): the same tables, each entry's size = its raw size, the code laid out again
    (the preload entries keep their old file ranges; only the shader tools read these copies)"""
    a = archive(b); r = R(b); r.take('<I')
    for elem in (20, 20, 16): r.raw(elem * r.take('<I'))
    head, ents_at = b[:r.o + 4], r.o + 4; n = len(a['shaders']); tail_at = ents_at + 17 * n
    ents, off = bytearray(), 0
    for (_, _, raw, fr), d in zip(a['shaders'], raws):
        if len(d) != raw: raise ValueError(f'decoded shader of {len(d)} bytes, the archive says {raw}')
        ents += struct.pack('<QIIB', off, raw, raw, fr); off += raw
    return head + bytes(ents) + b[tail_at:a['code']] + b''.join(raws)

def paks(romfs):
    """Every pak under the RomFS"""
    return sorted(os.path.join(dp, f) for dp, _, fs in os.walk(romfs) for f in fs if f.endswith('.pak'))

def unreal_paks(romfs, legacy=None):
    """The paks under the RomFS that Unreal wrote (its magic in the footer; legacy None = any version, True = the legacy versions, False = the others): with version 11 the NSP script decodes
    the shader code archives (decode_ue_shaders); legacy paks keep the shaders inline in the cooked packages, which shader_split.py reads through the game's decoder (ue_legacy_jobs)"""
    out = []
    for p in paks(romfs):
        try:
            with open(p, 'rb') as f: ver = pak_version(f)
        except (OSError, ValueError, struct.error): continue   # shorter than a footer, or no Unreal pak
        if legacy is None or (ver in LEGACY) == legacy: out.append(p)
    return out

def job(romfs, main_nso, work):
    """The shader code archives of every pak under the RomFS into <work>/archives, and one Oodle job (<work>/oodle.job) of every compressed shader in them; <work>/job.json lists them"""
    os.makedirs(os.path.join(work, 'archives'), exist_ok=True)
    img, lo, hi = nso_image(main_nso); key = None; listing, recs = [], []
    for pak in unreal_paks(romfs, legacy=False):
        with open(pak, 'rb') as f: enc = footer(f)[0]
        if enc and key is None:
            key = find_key(img, lo, hi, pak)
            if key is None: raise ValueError(f'{pak}: the index is encrypted and no window of main decrypts it')
        p = Pak(pak, key)
        for path in sorted(x for x in p.files if x.endswith('.ushaderbytecode')):
            b = p.read(path); a = archive(b); name = os.path.basename(path)
            open(os.path.join(work, 'archives', name), 'wb').write(b)
            comp = [i for i, (_, size, raw, _) in enumerate(a['shaders']) if size != raw]
            for i in comp:
                off, size, raw, _ = a['shaders'][i]; recs.append((name, i, b[a['code'] + off:a['code'] + off + size], raw))
            listing.append(dict(name=name, pak=os.path.relpath(pak, romfs), path=path, shaders=len(a['shaders']), compressed=len(comp)))
    with open(os.path.join(work, 'oodle.job'), 'wb') as f:
        f.write(struct.pack('<II', JOB_MAGIC, len(recs)))
        for _, _, c, raw in recs: f.write(struct.pack('<II', len(c), raw)); f.write(c)
    json.dump(dict(archives=listing, records=[(n, i) for n, i, _, _ in recs]), open(os.path.join(work, 'job.json'), 'w'), indent=1)
    return listing, len(recs)

def finish(work, out):
    """The decoded archives into out, from <work>/oodle.job.out (the host's results, in job order)"""
    meta = json.load(open(os.path.join(work, 'job.json')))
    b = open(os.path.join(work, 'oodle.job.out'), 'rb').read()
    magic, n = struct.unpack_from('<II', b)
    if magic != OUT_MAGIC or n != len(meta['records']): raise ValueError('the job output does not match the job')
    o, dec = 8, {}
    for name, i in meta['records']:
        l = struct.unpack_from('<I', b, o)[0]; o += 4
        if not l: raise ValueError(f'{name}: shader {i} was not decoded')
        dec[(name, i)] = b[o:o + l]; o += l
    os.makedirs(out, exist_ok=True)
    for x in meta['archives']:
        src = open(os.path.join(work, 'archives', x['name']), 'rb').read(); a = archive(src)
        raws = [dec.get((x['name'], i)) or src[a['code'] + off:a['code'] + off + size] for i, (off, size, _, _) in enumerate(a['shaders'])]
        tmp = os.path.join(out, x['name'] + '.partial'); open(tmp, 'wb').write(decoded_archive(src, raws)); os.replace(tmp, os.path.join(out, x['name']))
    return [x['name'] for x in meta['archives']]

def lslg(s):
    """A decoded Switch shader (LSLG): 'LSLG', a stage tag (SV vertex, SP pixel, SC compute, ...), a header with the shader's source name, then u32 code length, the code area,
    u32 control length and the control section (0x880 bytes), and a short tail (24 or 29 bytes). → (tag, control section, code area), or None if the layout differs"""
    if s[:4] != b'LSLG': return None
    k = s.find(b'\x34\x12\x76\x98')
    if k < 8: return None
    nctl, ncode = struct.unpack_from('<I', s, k - 4)[0], struct.unpack_from('<I', s, k + 0x704)[0]
    c = k - 4 - ncode
    if c < 4 or struct.unpack_from('<I', s, c - 4)[0] != ncode or k + nctl > len(s): return None
    return s[4:6].decode('latin1'), s[k:k + nctl], s[c:c + ncode]

# ---- UE5's IoStore: the shader records in a .ucas beside a .utoc (FINAL FANTASY RESONANCE) ----
# A .ucas holds UE's records; the shader ones start with the magic 'LSLG' and a stage tag ('SV' vertex, 'SP' pixel,
# 'SC' compute).  A shader record is: 'LSLG', the stage tag, two flag bytes, a u24 (big endian) size field whose
# first byte has bit 0x40 when the record's code is compressed, a header of UE's own (the shader's hashes, a GUID and
# the counts of its parameters and resources) that ends in a 20-byte hash, the shader's name (a printable path ending
# in .usf or .ush, the shader's function after a colon), a few bytes, then the code area: the graphics magic
# 0x12345678 or the compute magic 0x12345679, the SPH word 0 at +4 (its bits 10..13 are the stage, as in the other
# games' code areas but four bytes in, not 0x30) and the NVN code, then the control section (the magic
# 0x98761234, 0x880 bytes).  A chunk header (8C 0A ...) precedes every record.
# The .ucas's control section is the 0x98761234 blob that follows the code area (0x880 bytes, as in the shader code
# archives), but its fields are not the ones the other games' control sections have: +0x20 does not hold the
# section's own length, +0x704 does not hold the code area's length, and +0x748 leaves the compute thread group
# empty.  So the caller has to pass the code area's length itself (shader_split.py's check).
GFX_MAGIC_B, CS_MAGIC_B, CTL_MAGIC_B = b'\x78\x56\x34\x12', b'\x79\x56\x34\x12', b'\x34\x12\x76\x98'
IO_STAGE = {'SV': 'vs', 'SP': 'ps', 'SC': 'cs'}

def io_records(data):
    """The shader records in a .ucas: [(offset, stage)] in file order.  A record starts with the magic 'LSLG' and a
    stage tag; the .ucas holds other records (assets) with the same magic, so the shader ones are told apart by
    their name (a .usf or .ush path)."""
    out, pos = [], 0
    while True:
        i = data.find(b'LSLG', pos)
        if i < 0: break
        tag = data[i + 4:i + 6]
        if tag in (b'SV', b'SP', b'SC'): out.append((i, IO_STAGE[tag.decode()]))
        pos = i + 4
    return out

def io_record(data, off, limit):
    """A shader record: the stage, the name, the shader's hash, the code area's offset and length, the record's
    size field and whether the record's code is compressed.  The record is: 'LSLG', the stage tag, two flag bytes,
    a u24 (big endian) size field (the byte at +8 has bit 0x40 when the code is compressed), a header of UE's own
    that ends in a 20-byte hash, the shader's source name, then the code area (the graphics magic 0x78563412 or the
    compute magic 0x79563412).  The code area runs to the next record's chunk header.  A record whose name is not a
    .usf or .ush path is not a shader (the .ucas holds assets with the same magic) and comes back None.
    The code area ends where the control section begins (the magic 0x98761234), as in the shader code archives."""
    s = data[off:limit]
    if len(s) < 0x40: return None
    tag = s[4:6].decode('latin1')
    if tag not in IO_STAGE: return None
    compressed = bool(s[8] & 0x40)
    size = int.from_bytes(s[9:12], 'big')
    k = s.find(GFX_MAGIC_B)
    graphics = k >= 0
    if not graphics: k = s.find(CS_MAGIC_B)
    if k < 0: return None      # a compressed record: its code is not in the file as it is
    # a graphics code area holds an SPH word 0 four bytes in, whose bits 10..13 are the stage
    if graphics:
        w = struct.unpack_from('<I', s, k + 4)[0] if k + 8 <= len(s) else 0
        if not 1 <= (w >> 10) & 0xf <= 5: return None    # not a shader (an asset record with the same magic)
    elif tag != 'SC': return None
    # the name: the printable run before the code area (the bytes in between are not printable); it starts
    # with the path separator and ends with the shader's function
    e = k
    while e > 0 and not (32 <= s[e-1] < 127): e -= 1
    b0 = e
    while b0 > 0 and 32 <= s[b0-1] < 127: b0 -= 1
    b = s.find(b'/', b0, e)
    if b < 0: return None
    name = s[b:e].decode('utf-8', 'replace')
    if '.usf' not in name and '.ush' not in name: return None
    # the code area ends where the control section begins (the magic 0x98761234), as in the shader code archives
    ct = s.find(CTL_MAGIC_B, k)
    if ct < 0: return None
    return dict(stage=IO_STAGE[tag], name=name, hash=s[b-20:b].hex() if b >= 20 else '',
                code_at=off + k, code_len=ct - k, ctl_at=off + ct, ctl_len=0x880, size=size, compressed=compressed)

def io_extract(ucas, out):
    """The shader records of a UE5 IoStore .ucas into <out>: every shader as a file named
    <index>_<stage>_<name>.lsg (the code area and the control section) and a listing (shaders.json).
    The records whose code is compressed are listed but not written out: where their Oodle-compressed
    code lies and how long it is has not been found yet.  The .ucas holds other records (assets) with the
    same magic; they are not shaders and are left out.  → the list of shader records"""
    os.makedirs(out, exist_ok=True)
    with open(ucas, 'rb') as f:
        data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    n = len(data)
    recs = io_records(data)
    listing = []
    for k, (off, stage) in enumerate(recs):
        limit = recs[k + 1][0] if k + 1 < len(recs) else n
        r = io_record(data, off, limit)
        if not r:
            if data[off + 8] & 0x40:   # a shader whose code is compressed
                listing.append(dict(stage=stage, name='', file='', plain=False, code=0, compressed=True))
            continue
        base = f'{k:05d}_{r["stage"]}_' + re.sub(r'[^A-Za-z0-9_.-]', '_', os.path.basename(r['name']))[:80]
        with open(os.path.join(out, base + '.lsg'), 'wb') as f:
            f.write(data[r['code_at']:r['code_at'] + r['code_len']])
            f.write(data[r['ctl_at']:r['ctl_at'] + r['ctl_len']])
        listing.append(dict(stage=r['stage'], name=r['name'], file=base + '.lsg', plain=True,
                            code=r['code_len'], hash=r['hash'], size=r['size']))
    json.dump(listing, open(os.path.join(out, 'shaders.json'), 'w'), indent=1)
    return listing

def open_pak(pak, nso=None):
    """A pak opened for reading: its key, when the index is encrypted (Octopath Traveler 0), is looked for in main (the NSO), which is only needed then"""
    with open(pak, 'rb') as f: enc = footer(f)[0]
    key = None
    if enc:
        if not nso: raise ValueError(f'{pak}: the index is encrypted, the main NSO is needed for its key')
        img, lo, hi = nso_image(nso); key = find_key(img, lo, hi, pak)
        if key is None: raise ValueError(f'{pak}: the index is encrypted and no window of main decrypts it')
    return Pak(pak, key)

if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'list':
        pak = sys.argv[2]
        # the main NSO is only needed for an encrypted index: list <pak> <main NSO> <out tsv> or list <pak> <out tsv>
        nso, out = (sys.argv[3], sys.argv[4]) if len(sys.argv) > 4 else (None, sys.argv[3])
        p = open_pak(pak, nso)
        with open(out, 'w') as f:
            f.write('path\traw\tstored\tmethod\tencrypted\tblocks\n')
            for path in sorted(p.files):
                e = p.entry(path); f.write(f"{path}\t{e['raw']}\t{e['size']}\t{e['method'] or 'none'}\t{e['encrypted']}\t{len(e['blocks'])}\n")
        used = sorted({p.entry(x)['method'] for x in p.files} - {''})
        print(f'pak version {p.version}, mount {p.mount}, {len(p.files)} files, compression {used}')
    elif cmd == 'job':
        listing, n = job(*sys.argv[2:5])
        for x in listing: print(f"{x['name']}: {x['shaders']} shaders, {x['compressed']} compressed")
        print(f'{n} records in {os.path.join(sys.argv[4], "oodle.job")}')
    elif cmd == 'finish':
        print('decoded:', ', '.join(finish(*sys.argv[2:4])))
    elif cmd == 'extract':
        # extract <pak> [<main NSO>] <path> <out file>: the file's bytes. A file only the game's own decoder can read (Oodle) is written as it is stored,
        # with its compressed blocks in <out file>.oodle.job (the same job the `job` command writes, which the Mac host decodes)
        pak = sys.argv[2]
        rest = sys.argv[3:]
        nso, path, out = (rest[0], rest[1], rest[2]) if len(rest) > 3 else (None, rest[0], rest[1])
        p = open_pak(pak, nso); e = p.entry(path); meth = e['method']
        if not meth:
            data, note = p.read(path), 'not compressed'
        elif meth in ('Zlib', 'Gzip'):
            import zlib, gzip
            data = p.read(path, decode=(lambda b, n: zlib.decompress(b)) if meth == 'Zlib' else (lambda b, n: gzip.decompress(b)))
            note = f'{meth}-compressed, decoded here'
        else:
            data = p.stored(path)
            note = f'{meth}-compressed: the stored blocks are written, the game\'s own {meth} (the Mac host) is needed for the raw bytes'
            job = out + '.oodle.job'
            with open(job, 'wb') as f:
                f.write(struct.pack('<II', JOB_MAGIC, len(e['blocks'])))
                left = e['raw']
                for s, n in e['blocks']:
                    k = min(left, e['block_size']) if e['block_size'] else left
                    f.write(struct.pack('<II', n, k)); f.write(p.read_at(e['off'] + s, n, e['encrypted'])); left -= k
            note += f'; the {len(e["blocks"])} compressed blocks are in {job}'
        open(out, 'wb').write(data)
        print(f'{path}: {e["raw"]} bytes raw, {e["size"]} stored, {meth or "not compressed"}, {len(e["blocks"])} blocks, {len(data)} bytes written ({note})')
    elif cmd == 'io':
        # io <ucas> <out dir>: the shader records of a UE5 IoStore .ucas
        listing = io_extract(sys.argv[2], sys.argv[3])
        plain = sum(1 for x in listing if x['plain'])
        comp = sum(1 for x in listing if x.get('compressed'))
        print(f'{len(listing)} shader records ({plain} plain, {comp} with compressed code)')
    else: sys.exit(__doc__ or 'usage: uepak.py list | job | finish | io (see the header)')
