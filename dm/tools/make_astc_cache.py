#!/usr/bin/env python3
"""Build the runtime BCA1 ASTC cache from a DM_NVN_BC_DUMP folder (TGA per level/layer + dump.tsv).

Usage: make_astc_cache.py <dump dir> <cache dir> [astcenc]
  astcenc defaults to $ASTCENC, then to "astcenc" on PATH. Pass the resulting
  directory to build_ipa.sh with DM_BC_ASTC=<cache dir> (A16=1 defaults it to
  $W/astc-cache).

The Mac host writes the dump when DM_NVN_BC_DUMP points at an empty directory;
the cache is keyed by the same guest texture hash and is not reproducible from
anything else. It belongs to one game and one set of game files.
"""
import os
import struct
import subprocess
import sys
import tempfile

if len(sys.argv) < 3:
    sys.exit(__doc__)

dump, out = sys.argv[1], sys.argv[2]
astcenc = sys.argv[3] if len(sys.argv) > 3 else os.environ.get('ASTCENC') or 'astcenc'
os.makedirs(out, exist_ok=True)
rows = []
for line in open(os.path.join(dump, 'dump.tsv')):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    rows.append(line.split('\t'))
print('textures:', len(rows))
for i, r in enumerate(rows):
    h, fmt, w, hgt, levels, layers, srgb = r[0], int(r[1], 0), int(r[2]), int(r[3]), int(r[4]), int(r[5]), int(r[6])
    blocks = bytearray()
    for l in range(levels):
        for a in range(layers):
            tga = os.path.join(dump, f'{h}_l{l}_a{a}.tga')
            if not os.path.isfile(tga):
                print('missing', tga)
                sys.exit(1)
            fd, tmp = tempfile.mkstemp(suffix='.astc')
            os.close(fd)
            cmd = [astcenc, '-cs' if srgb else '-cl', tga, tmp, '4x4', '-medium']
            p = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            if p.returncode:
                print('astcenc failed', tga, p.stderr.decode()[-300:])
                sys.exit(1)
            d = open(tmp, 'rb').read()
            os.unlink(tmp)
            if len(d) < 16 or d[:4] != b'\x13\xab\xa1\x5c':
                print('bad astc', tga)
                sys.exit(1)
            bx, by, bz = d[4], d[5], d[6]
            dx = d[7] | d[8] << 8 | d[9] << 16
            dy = d[10] | d[11] << 8 | d[12] << 16
            blocks += d[16:]
            mw, mh = max(1, w >> l), max(1, hgt >> l)   # checkerboard of mip levels: the ASTC header holds this level's size, not the base size
            if bx != 4 or by != 4 or dx < mw or dy < mh:
                print('unexpected astc header', tga, bx, by, dx, dy, 'expected at least', mw, mh)
                sys.exit(1)
    hdr = b'BCA1' + struct.pack('<7I', 1, levels, layers, w, hgt, fmt, srgb)
    open(os.path.join(out, h + '.astc'), 'wb').write(hdr + blocks)
    if (i + 1) % 2 == 0:
        print(f'{i+1}/{len(rows)}')
print('done', out)
