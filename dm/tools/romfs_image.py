#!/usr/bin/env python3
# Pack an extracted RomFS folder into one image file the host reads in place of the folder (hle_fs.c, "RomFS image"): DM_ROMFS may name the image instead of a folder.
# One file instead of hundreds of thousands copies to an iPhone at full speed (Tears of the Kingdom's 304,000 files ran the phone's file service out of open files), and the host
# keeps one descriptor open for the whole RomFS.
# Layout (little-endian):
#   header  32 bytes: magic "DMROMFS1", u64 index offset, u64 index size, u64 entry count
#   data    each file's bytes, one after another
#   index   entry count entries of 24 bytes: u64 a, u64 b, u32 name offset, u16 name length, u8 type (0 directory, 1 file), u8 0
#           a directory: a = its first child's entry, b = its number of children; a file: a = data offset in the image, b = size
#           then the names, one pool. Entry 0 is the root (empty name). Each directory's children are consecutive entries sorted by name (bytes), so a lookup is a
#           binary search per path component; directories are numbered breadth-first.
# The index comes last, so a copy cut off partway has no valid index (the header points past the end of the file) and the host refuses it.
# Names are the guest names: a host name chosen on a case collision (.dm-case-N) is replaced by the one in its xattr, as hle_fs.c's guest_name does.
# Usage: romfs_image.py <RomFS folder> <out image>   (written to <out>.part, renamed at the end)
import os, struct, subprocess, sys

MAGIC = b'DMROMFS1'
HEAD = struct.Struct('<8sQQQ')
ENT = struct.Struct('<QQIHBB')
GUEST_NAME = 'org.d2rmobile.guest-name'


def guest(parent, name):
    if not name.startswith('.dm-case-'): return name
    r = subprocess.run(['xattr', '-p', GUEST_NAME, os.path.join(parent, name)], capture_output=True, text=True)
    return r.stdout.rstrip('\n') if r.returncode == 0 else name


def children(path):
    out = []
    with os.scandir(path) as it:
        for e in it:
            out.append((guest(path, e.name).encode(), e.path, e.is_dir(follow_symlinks=True)))
    out.sort()
    return out


def pack(src, dst):
    ents = [[b'', src, True, 0, 0]]   # name, host path, is dir, a, b
    i = 0
    while i < len(ents):   # breadth-first: each directory's children land as one consecutive run
        name, path, isdir, _, _ = ents[i]
        if isdir:
            kids = children(path)
            ents[i][3], ents[i][4] = len(ents), len(kids)
            ents.extend([n, p, d, 0, 0] for n, p, d in kids)
        i += 1
    part = dst + '.part'
    with open(part, 'wb') as out:
        out.write(b'\0' * HEAD.size)
        off = HEAD.size
        for e in ents:
            if e[2]: continue
            with open(e[1], 'rb') as f:
                n = 0
                while True:
                    b = f.read(8 << 20)
                    if not b: break
                    out.write(b); n += len(b)
            e[3], e[4] = off, n; off += n
        pool, idx = bytearray(), bytearray()
        for name, _, isdir, a, b in ents:
            idx += ENT.pack(a, b, len(pool), len(name), 0 if isdir else 1, 0); pool += name
        out.write(idx); out.write(pool)
        out.seek(0); out.write(HEAD.pack(MAGIC, off, len(idx) + len(pool), len(ents)))
    os.replace(part, dst)
    return len(ents)


def read_index(img):   # for tests and checks: {guest path: (is dir, offset, size)}
    with open(img, 'rb') as f:
        magic, ioff, isz, n = HEAD.unpack(f.read(HEAD.size))
        assert magic == MAGIC
        f.seek(ioff); raw = f.read(isz)
    pool = raw[n * ENT.size:]
    e = [ENT.unpack_from(raw, k * ENT.size) for k in range(n)]
    out, todo = {}, [(0, '')]
    while todo:
        k, path = todo.pop()
        a, b, no, nl, t, _ = e[k]
        if t == 0:
            if path: out[path] = (True, 0, 0)
            todo.extend((c, (path + '/' if path else '') + pool[e[c][2]:e[c][2] + e[c][3]].decode()) for c in range(a, a + b))
        else: out[path] = (False, a, b)
    return out


if __name__ == '__main__':
    if len(sys.argv) != 3: sys.exit('usage: romfs_image.py <RomFS folder> <out image>')
    n = pack(sys.argv[1], sys.argv[2])
    print(f'{sys.argv[2]}: {n} entries, {os.path.getsize(sys.argv[2])} bytes')
