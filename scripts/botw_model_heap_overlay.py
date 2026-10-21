#!/usr/bin/env python3
"""Write a RomFS overlay whose resource size table gives model files extra heap room.

Every recorded world-load crash of the nxnative build is the same one: while the game
sets up Model/Obj_TreeConiferous.bfres, a 0x78-byte allocation from the file's resource
heap returns null (main+0x155a79c, written through at main+0x155a7a4). That heap is sized
by the RSTB entry (0x29e520 = the 0x19b010-byte file plus 0x103378 of room), and on the
Mac the setup sometimes needs a little more than that room. A larger RSTB entry only
makes the game create a larger heap for the file; the file itself is unchanged.

usage: botw_model_heap_overlay.py ROMFS OVERLAY_DIR
"""
import argparse, struct, zlib
from pathlib import Path

# Spyder/F5: set both paths here, or pass them on the command line.
ROMFS = None
OVERLAY_DIR = None

PAD_ALL_MODELS = 0x10000              # every Model/*.bfres that is not a texture archive
PAD_NAMED = {'Model/Obj_TreeConiferous.bfres': 0x80000}
RSTB = 'System/Resource/ResourceSizeTable.product.srsizetable'


def yaz0_decode(d):
    assert d[:4] == b'Yaz0'
    size = struct.unpack('>I', d[4:8])[0]
    out, p = bytearray(), 16
    while len(out) < size:
        code = d[p]; p += 1
        for bit in range(8):
            if len(out) >= size:
                break
            if code & (0x80 >> bit):
                out.append(d[p]); p += 1
                continue
            b1, b2 = d[p], d[p + 1]; p += 2
            dist, n = ((b1 & 15) << 8 | b2) + 1, b1 >> 4
            if n == 0:
                n = d[p] + 0x12; p += 1
            else:
                n += 2
            for _ in range(n):
                out.append(out[-dist])
    return bytes(out)


def yaz0_store(d):
    """Yaz0 with every byte a literal: valid for any Yaz0 reader, no compression needed."""
    out = bytearray(b'Yaz0' + struct.pack('>I', len(d)) + bytes(8))
    for i in range(0, len(d), 8):
        chunk = d[i:i + 8]
        out.append(0xFF)
        out += chunk
    return bytes(out)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('romfs', nargs='?', default=ROMFS)
    parser.add_argument('overlay_dir', nargs='?', default=OVERLAY_DIR)
    args = parser.parse_args(argv)
    if not args.romfs or not args.overlay_dir:
        parser.error('pass ROMFS and OVERLAY_DIR, or set them at the top of the script for F5')
    romfs, overlay = Path(args.romfs), Path(args.overlay_dir)
    if romfs.resolve() == overlay.resolve():
        parser.error('OVERLAY_DIR must differ from ROMFS; the original table is never overwritten')
    data = bytearray(yaz0_decode((romfs / RSTB).read_bytes()))
    assert data[:4] == b'RSTB'
    ncrc, nname = struct.unpack('<II', data[4:12])
    names = {}
    for f in romfs.joinpath('Model').glob('*.sbfres'):
        n = 'Model/' + f.name[:-len('.sbfres')] + '.bfres'
        if '.Tex' not in n:
            names[zlib.crc32(n.encode())] = n
    padded, extra = 0, 0
    for i in range(ncrc):
        p = 12 + i * 8
        crc, size = struct.unpack('<II', data[p:p + 8])
        name = names.get(crc)
        if not name:
            continue
        add = PAD_NAMED.get(name, PAD_ALL_MODELS)
        data[p + 4:p + 8] = struct.pack('<I', size + add)
        padded += 1; extra += add
    p = 12 + ncrc * 8
    for i in range(nname):
        q = p + i * 132
        name = data[q:q + 128].split(b'\0')[0].decode()
        if name.startswith('Model/') and name.endswith('.bfres') and '.Tex' not in name:
            add = PAD_NAMED.get(name, PAD_ALL_MODELS)
            size = struct.unpack('<I', data[q + 128:q + 132])[0]
            data[q + 128:q + 132] = struct.pack('<I', size + add)
            padded += 1; extra += add
    out = overlay / RSTB
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(yaz0_store(bytes(data)))
    assert yaz0_decode(out.read_bytes()) == bytes(data)
    print(f'{padded} model entries padded, {extra / 2**20:.1f} MB if all were loaded at once -> {out}')


if __name__ == '__main__':
    main()
