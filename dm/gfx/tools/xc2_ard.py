#!/usr/bin/env python3
"""Monolith Soft bf2.arh / bf2.ard archive reader (Xenoblade Chronicles 2), after XbTool's FileArchive.cs (Alex Barney, MIT).
  xc2_ard.py list <arh>                      -> path \t type \t compressed \t size
  xc2_ard.py extract <arh> <ard> <out> [glob] -> files under <out>, type-2 entries inflated (xbc1 + zlib)"""
import fnmatch, os, re, struct, sys, zlib

def read_arh(path):
    a = bytearray(open(path, 'rb').read())
    w = list(struct.unpack_from('<%di' % (len(a) // 4), a))
    key = (w[9] ^ 0xF3F35353) & 0xffffffff
    if key & 0x80000000: key -= 1 << 32
    st, sl, nt, nl = w[3] // 4, w[4] // 4, w[5] // 4, w[6] // 4
    for i in list(range(st, st + sl)) + list(range(nt, nt + nl)): w[i] ^= key
    a = bytearray(struct.pack('<%di' % len(w), *w))
    node_count, st_off, st_len, nt_off, nt_len, ft_off, fcount = struct.unpack_from('<7i', a, 8)
    strings = bytes(a[st_off:st_off + st_len])
    nodes = [struct.unpack_from('<ii', a, nt_off + 8 * i) for i in range(node_count)]
    files = [list(struct.unpack_from('<qiiii', a, ft_off + 0x18 * i)) + [None] for i in range(fcount)]
    for i, (nxt, prv) in enumerate(nodes):
        if nxt >= 0 or prv < 0: continue
        o = -nxt; e = strings.index(b'\0', o)
        suffix = strings[o:e].decode('utf8', 'replace'); fid = struct.unpack_from('<i', strings, e + 1)[0]
        chars = []; cur = i
        while nodes[cur][0] != 0:
            prev = nodes[cur][1]; chars.append(chr(cur ^ nodes[prev][0])); cur = prev
        files[fid][5] = ''.join(reversed(chars)) + suffix
    return files   # [offset, csize, usize, type, id, name]

def read_entry(f, e):
    off, cs, us, typ = e[:4]
    f.seek(off)
    if typ == 2:
        f.read(0x30); return zlib.decompress(f.read(cs))
    return f.read(cs)

if __name__ == '__main__':
    cmd = sys.argv[1]; files = read_arh(sys.argv[2])
    if cmd == 'list':
        for e in files:
            if e[5]: print(f'{e[5]}\t{e[3]}\t{e[1]}\t{e[2]}')
    elif cmd == 'extract':
        out = sys.argv[4]; pat = sys.argv[5] if len(sys.argv) > 5 else '*'
        with open(sys.argv[3], 'rb') as f:
            for e in files:
                if not e[5] or not fnmatch.fnmatch(e[5].lower(), pat.lower()): continue
                p = os.path.join(out, e[5].lstrip('/')); os.makedirs(os.path.dirname(p), exist_ok=True)
                open(p, 'wb').write(read_entry(f, e))

CTL_MAGIC, GFX_MAGIC, CS_MAGIC = bytes.fromhex('34127698'), bytes.fromhex('78563412'), bytes.fromhex('79563412')

def xbc1_streams(d):
    """d itself and every xbc1 stream in it, inflated: {'xbc1', u32 type, u32 length, u32 stored length, ...; zlib at +0x30}"""
    out = [(0, d)]
    for m in re.finditer(b'xbc1', d):
        o = m.start(); us, cs = struct.unpack_from('<II', d, o + 8)
        try: x = zlib.decompress(d[o + 0x30:o + 0x30 + cs])
        except zlib.error: continue
        if len(x) == us: out.append((o, x))
    return out

def spch_programs(d):
    """Monolith's Spch ('HCPS', version 0x3f2) shader packages: control sections laid out back to back from header +0x28 (length +0x2c), code areas back to back from +0x20 (length +0x24), in
    the same order, each code area at 0x100-byte alignment. → [(HCPS offset, control offset, control section, code area)]"""
    out = []
    for m in re.finditer(b'HCPS', d):
        h = m.start()
        if h + 0x30 > len(d) or struct.unpack_from('<I', d, h + 4)[0] != 0x3f2: continue
        bo, bl, co, cl = struct.unpack_from('<4I', d, h + 0x20)
        if not (0 < bo and h + bo + bl <= len(d) and h + co + cl <= len(d)): continue
        ptr, end = h + bo, h + bo + bl
        for c in [x.start() for x in re.finditer(re.escape(CTL_MAGIC), d[h + co:h + co + cl])]:
            c += h + co
            if c & 3: continue
            nctl, n = struct.unpack_from('<I', d, c + 0x20)[0], struct.unpack_from('<I', d, c + 0x704)[0]
            if not 0x760 <= nctl <= 0x880 or ptr + n > end: continue
            out.append((h, c, d[c:c + nctl], d[ptr:ptr + n])); ptr += (n + 0xff) & ~0xff
    return out
