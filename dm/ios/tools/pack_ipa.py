#!/usr/bin/env python3
# Pack the IPA (a zip archive) straight from its source folders: the app Xcode built, the iOS shader libraries, the add-on content and the RomFS, each under its own path in the archive,
# with no Payload/ copy first. Replaces zip -qry -n with the same entries: folders, Unix modes (the executable's x bit), symlinks as links, DOS times, the UTF-8 flag for non-ASCII names;
# deflate level 6, a file whose deflate is not smaller is stored (zip's rule), and names ending in a --store suffix are always stored (the profile's zip_store, compared without regard to case).
# Speed (Info-ZIP managed about 100 MB/s on the T7): files up to BIG are read, and deflated, by a thread pool (zlib releases the GIL) while this thread writes them in order;
# bigger files are streamed here, their CRC patched into the local header afterwards (no data descriptors). Zip64 fields wherever a size, an offset or the entry count passes its 32 / 16-bit field.
# Usage: pack_ipa.py <out.ipa> [--store .a:.b] [--skip <archive path>]... <archive path>=<source folder>...
#   The mappings are packed in a fixed order, whatever the command line's: the RomFS, the add-on content, the pipeline archive, the shader libraries, other mappings, and a mapping that
#   holds others after them (the app last), so the files that change least lead the archive
#   --skip: an archive path left out of the walk of the folder that holds it (folders a stale app build still has, the signature); a mapping of its own still adds it
#   --skip-suffix: files whose names end so are left out of every walk (build_ipa.sh: the pulling vertex libraries _bp.metallib when the profile's pso_mtl4 is off, unless IOS_PULL overrides it)
#   Writes <out.ipa>.partial and renames it at the end; prints "pack: N entries, X bytes" first (the NSP script's progress total, X = the files' bytes) and a summary line last
#   Repeat packs: <out.ipa>.idx (written after the rename) records the IPA's size, time and central directory offset, the deflate level, and each entry in archive order: its name, kind,
#   local header offset and length, data length, and for a file its source's size, times, inode and deflate flag with its method, CRC, compressed size and data offset (for a folder or a
#   symlink its local header bytes). The longest leading run of entries that still match, byte for byte, is kept: the old IPA is cloned (APFS clonefile) and cut after that run, so those
#   bytes are not written again (a full write where cloning fails). After it, a file whose row still matches is copied compressed from the old IPA; --no-reuse packs every file again
import argparse, collections, concurrent.futures as cf, ctypes, json, os, stat, struct, sys, time, zlib

LEVEL = 6
IDX_VERSION = 2
BIG = 256 << 20      # files above this are streamed by the writer; smaller ones go through the pool
WINDOW = 2 << 30     # input bytes in the pool at once
QUEUE = 4096         # entries in the pool at once (folders of tiny files)
CHUNK = 16 << 20
L32, L16 = 0xFFFFFFFF, 0xFFFF
DIR_MODE = stat.S_IFDIR | 0o755   # a parent folder no source folder stands for (Payload/, msl/); its time is 1980-01-01, so it is the same in every pack
ORDER = ('romfs', 'aoc', 'pso', 'msl')   # the mappings that lead the archive, in this order
Entry = collections.namedtuple('Entry', 'name path st')   # st None: such a parent folder


def order(maps):   # by ORDER (a path component), descendants before their parent mapping, then by archive path
    def key(m):
        arc = m[0]
        return next((i for i, n in enumerate(ORDER) if f'/{n}/' in f'/{arc}/'), len(ORDER)), -arc.count('/'), arc
    return sorted(maps, key=key)


def entries(maps, skip, skip_suffix=()):
    """The archive's entries in order: for each mapping its parent folders (unless an earlier entry gave them), its root, then its tree depth first, sorted by name,
    without the skipped paths and without other mappings' roots (each adds its own). A mapped parent folder stays with its mapping, so an app folder's new time cannot cut its children's
    kept prefix. Other parent folders are written once where the first mapping under them needs them, with their owner's metadata"""
    roots, out, seen, parents = {a for a, _ in maps}, [], set(), set()
    def add(name, path, st):
        if name in parents and st is not None and stat.S_ISDIR(st.st_mode): return   # written already, as a parent folder
        if name in seen: sys.exit(f'[RED] pack_ipa: {name} twice in the archive')
        seen.add(name); out.append(Entry(name, path, st))
    def owner(p):   # the source folder that stands for parent folder p (archive path without the slash), or None
        best = max((m for m in maps if p == m[0] or p.startswith(m[0] + '/')), key=lambda m: len(m[0]), default=None)
        if best is None: return None
        if p == best[0]: return best[1]
        path = os.path.join(best[1], p[len(best[0]) + 1:])
        return None if p in skip or not os.path.isdir(path) or os.path.islink(path) else path
    def walk(d, arc):
        with os.scandir(d) as it: es = sorted(it, key=lambda e: e.name)
        for e in es:
            name = f'{arc}/{e.name}'
            if name in skip or name in roots or (skip_suffix and e.name.endswith(skip_suffix) and not e.is_dir(follow_symlinks=False)): continue
            st = e.stat(follow_symlinks=False)
            if stat.S_ISDIR(st.st_mode): add(name + '/', e.path, st); walk(e.path, name)
            elif stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode): add(name, e.path, st)
            else: sys.exit(f'[RED] pack_ipa: neither a file, a folder nor a symlink: {e.path}')
    for arc, src in maps:
        parts = arc.split('/')
        for i in range(1, len(parts)):
            p = '/'.join(parts[:i])
            if p not in roots and p + '/' not in seen:
                path = owner(p); add(p + '/', path, path and os.stat(path)); parents.add(p + '/')
        add(arc + '/', src, os.stat(src)); walk(src, arc)
    return out


def load(path, deflate):   # in the pool: (method, CRC, the bytes to write)
    with open(path, 'rb') as f: data = f.read()
    crc = zlib.crc32(data)
    if deflate and data:
        c = zlib.compressobj(LEVEL, zlib.DEFLATED, -15); z = c.compress(data) + c.flush()
        if len(z) < len(data): return 8, crc, z
    return 0, crc, data


def dos_time(t):
    y, mo, d, h, mi, s = time.localtime(t)[:6]
    if y < 1980: y, mo, d, h, mi, s = 1980, 1, 1, 0, 0, 0
    return (h << 11) | (mi << 5) | (s // 2), ((y - 1980) << 9) | (mo << 5) | d


def header(e, method, crc, csize, usize, z64=False):   # a local header: (its bytes, name bytes, flags, time, date)
    nb = e.name.encode('utf-8', 'surrogateescape'); fl = 0 if e.name.isascii() else 0x800
    t, d = dos_time(e.st.st_mtime if e.st else 0)
    ext = struct.pack('<HHQQ', 1, 16, usize, csize) if z64 else b''
    return (struct.pack('<IHHHHHIIIHH', 0x04034B50, 45 if z64 else 20 if method == 8 else 10, fl, method, t, d, crc, L32 if z64 else csize, L32 if z64 else usize, len(nb), len(ext))
            + nb + ext, nb, fl, t, d)


def clone(src, dst):   # an APFS clone of src at dst (which must not exist); False where the platform or the volume has none
    try: return ctypes.CDLL(None, use_errno=True).clonefile(os.fsencode(src), os.fsencode(dst), 0) == 0
    except (AttributeError, OSError): return False


class Zip:
    def __init__(self, path, keep=0):   # keep: the bytes of a clone at path that stay (the leading entries kept)
        self.f = open(path, 'r+b' if keep else 'wb', buffering=1 << 20)
        if keep: self.f.truncate(keep); self.f.seek(keep)
        self.pos, self.cd, self.written = keep, [], 0   # written: the bytes this pack writes (entries, header patches, the central directory; main adds the index)
        self.stats, self.rows = collections.Counter(), []   # rows: the index rows of the entries in archive order, for <out.ipa>.idx

    def row(self, e, kind, h, csize, x):
        self.rows.append([e.name, kind, h[0], h[1], csize, x])

    def frow(self, e, h, deflate, method, crc, csize):   # a file's row; h: (header offset, header length)
        st = e.st; self.row(e, 'f', h, csize, [st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_ino, deflate, method, crc, csize, h[0] + h[1]])

    def w(self, b):
        self.f.write(b); self.pos += len(b); self.written += len(b)

    def local(self, e, method, crc, csize, usize, z64=False):   # writes the local header; returns (its offset, name bytes, flags, time, date, header bytes)
        b, nb, fl, t, d = header(e, method, crc, csize, usize, z64); off = self.pos; self.w(b)
        return off, nb, fl, t, d, b

    def central(self, e, h, method, crc, csize, usize):
        off, nb, fl, t, d = h[:5]
        z = [v for v in (usize, csize, off) if v >= L32]   # zip64 extra: the fields that do not fit, in this order
        ext = struct.pack(f'<HH{len(z)}Q', 1, 8 * len(z), *z) if z else b''
        mode = e.st.st_mode if e.st else DIR_MODE
        self.cd.append(struct.pack('<IHHHHHHIIIHHHHHII', 0x02014B50, 0x031E, 45 if z else 20 if method == 8 else 10, fl, method, t, d, crc, min(csize, L32), min(usize, L32),
                                   len(nb), len(ext), 0, 0, 0, (mode << 16) | (0x10 if stat.S_ISDIR(mode) else 0), min(off, L32)) + nb + ext)
        self.stats['deflated' if method == 8 else 'stored'] += usize; self.stats['out'] += csize

    def kept(self, k):   # a leading entry kept in the clone: its central row, stats and index row as written before
        e, off, h, method, crc, csize, usize, kind, x = k
        self.central(e, (off,) + h[1:], method, crc, csize, usize); self.row(e, kind, (off, len(h[0])), csize, x)
        if kind == 'f': self.stats['reused'] += 1

    def put(self, e, method, crc, data, usize, deflate=None):   # an entry whose bytes are at hand; deflate: a file's deflate flag, for its index row
        h = self.local(e, method, crc, len(data), usize)
        if deflate is not None: self.frow(e, (h[0], len(h[5])), deflate, method, crc, len(data))
        if data: self.w(data)
        self.central(e, h, method, crc, len(data), usize)
        return h

    def other(self, e):   # a folder or a symlink
        if e.st and stat.S_ISLNK(e.st.st_mode):
            t = os.readlink(e.path).encode('utf-8', 'surrogateescape'); h = self.put(e, 0, zlib.crc32(t), t, len(t)); kind = 'l'
        else: h = self.put(e, 0, 0, b'', 0); kind = 'd'
        self.row(e, kind, (h[0], len(h[5])), self.pos - h[0] - len(h[5]), h[5].hex())

    def patch(self, at, b):
        self.f.seek(at); self.f.write(b); self.written += len(b)

    def stream(self, e, deflate, flag=None):   # a big file: the local header first, its CRC (and a deflated size) patched in afterwards; flag: the deflate flag asked for
        flag = deflate if flag is None else flag
        usize = e.st.st_size; z64 = usize >= L32   # a deflate that is not smaller is redone stored, so the deflated size stays below usize
        h = self.local(e, 8 if deflate else 0, 0, 0 if deflate else usize, usize, z64); doff = self.pos
        crc, csize, c = 0, 0, zlib.compressobj(LEVEL, zlib.DEFLATED, -15) if deflate else None
        with open(e.path, 'rb') as f:
            while b := f.read(CHUNK):
                crc = zlib.crc32(b, crc)
                if c: b = c.compress(b)
                self.w(b); csize += len(b)
            if c: b = c.flush(); self.w(b); csize += len(b)
        if csize != usize and not c: sys.exit(f'[RED] pack_ipa: {e.path} changed size while it was packed')
        if c and csize >= usize:   # not smaller: stored instead
            self.f.seek(h[0]); self.f.truncate(); self.pos = h[0]; return self.stream(e, False, flag)
        self.patch(h[0] + 14, struct.pack('<I', crc) + (b'' if z64 else struct.pack('<II', csize, usize)))
        if z64: self.patch(h[0] + 30 + len(h[1]) + 4, struct.pack('<QQ', usize, csize))
        self.f.seek(self.pos)
        self.central(e, h, 8 if c else 0, crc, csize, usize); self.frow(e, (h[0], doff - h[0]), flag, 8 if c else 0, crc, csize)

    def reuse(self, e, r, old):   # a file whose index row matches: its compressed bytes copied from the old IPA (a file object), CHUNK at a time
        method, crc, csize, doff, usize = r[5], r[6], r[7], r[8], e.st.st_size
        h = self.local(e, method, crc, csize, usize, usize >= L32 or csize >= L32); self.frow(e, (h[0], len(h[5])), r[4], method, crc, csize)
        left, at = csize, doff
        while left:
            b = os.pread(old.fileno(), min(CHUNK, left), at)
            if not b: sys.exit(f'[RED] pack_ipa: the old IPA ended while {e.name} was copied from it')
            self.w(b); left -= len(b); at += len(b)
        self.central(e, h, method, crc, csize, usize)
        self.stats['reused'] += 1; self.stats['copied'] += csize

    def close(self):   # the central directory and the end records (zip64 ones when the count, the size or the offset does not fit)
        self.cd_off, n = self.pos, len(self.cd); blob = b''.join(self.cd); self.w(blob)
        if n >= L16 or self.cd_off >= L32 or len(blob) >= L32:
            z = self.pos
            self.w(struct.pack('<IQHHIIQQQQ', 0x06064B50, 44, 0x031E, 45, 0, 0, n, n, len(blob), self.cd_off))
            self.w(struct.pack('<IIQI', 0x07064B50, 0, z, 1))
        self.w(struct.pack('<IHHHHIIH', 0x06054B50, 0, 0, min(n, L16), min(n, L16), min(len(blob), L32), min(self.cd_off, L32), 0))
        self.f.close()


def load_index(out):   # (the old IPA opened, its index) when <out>.idx describes the IPA there now and this deflate level, else None
    try:
        with open(out + '.idx') as f: idx = json.load(f)
        old = open(out, 'rb'); st = os.fstat(old.fileno())
    except (OSError, ValueError): return None
    if not (isinstance(idx, dict) and idx.get('version') == IDX_VERSION and idx.get('level') == LEVEL and idx.get('ipa') == [st.st_size, st.st_mtime_ns]
            and type(idx.get('cd')) is int and 0 <= idx['cd'] <= st.st_size and isinstance(idx.get('entries'), list)):
        old.close(); return None
    return old, idx


def match(r, e, deflate, old, size):   # whether index row r still describes file e (its source unchanged, its bytes in the old IPA of this size where the row says)
    st = e.st
    if not (isinstance(r, list) and len(r) == 9 and all(type(v) is int for v in r[:4] + r[5:]) and type(r[4]) is bool
            and r[:5] == [st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_ino, deflate]): return False
    method, crc, csize, doff = r[5:]
    if method not in (0, 8) or not 0 <= crc <= L32 or csize < 0 or (method == 0 and csize != st.st_size) or doff < 0 or doff + csize > size: return False
    nb = e.name.encode('utf-8', 'surrogateescape')
    for ext in (0, 20):   # its local header ends at doff: the name, and a zip64 extra when the file was streamed past 4 GB
        h = doff - 30 - len(nb) - ext
        if h < 0: continue
        b = os.pread(old.fileno(), 30 + len(nb) + ext, h)
        if len(b) < 30 + len(nb) + ext: continue
        sig, _, _, m, _, _, c = struct.unpack_from('<IHHHHHI', b); nl, el = struct.unpack_from('<HH', b, 26)
        cs, us = struct.unpack_from('<II', b, 18)
        sizes = struct.pack('<HHQQ', 1, 16, st.st_size, csize) if ext else b''
        if ((sig, m, c, nl, el, cs, us) == (0x04034B50, method, crc, len(nb), ext, L32 if ext else csize, L32 if ext else st.st_size)
                and b[30:30 + len(nb)] == nb and b[30 + len(nb):] == sizes): return True
    return False


def prefix(es, flags, rows, old, cd):   # the leading entries whose rows, local headers and data in the old IPA are what this pack writes, back to back from offset 0, and where they end
    keep, pos, fd, size = [], 0, old.fileno(), os.fstat(old.fileno()).st_size
    for e, deflate, r in zip(es, flags, rows):
        if not (isinstance(r, list) and len(r) == 6 and r[0] == e.name and r[1] in ('f', 'd', 'l') and all(type(v) is int and v >= 0 for v in r[2:5]) and r[2] == pos): break
        _, kind, off, hlen, csize, x = r
        mode = e.st.st_mode if e.st else DIR_MODE; data = b''
        if kind == 'f':
            if not (stat.S_ISREG(mode) and match(x, e, deflate, old, size) and x[8] == off + hlen): break
            method, crc, usize = x[5], x[6], e.st.st_size
        elif kind == 'd':
            if not (stat.S_ISDIR(mode) and csize == 0): break
            method = crc = usize = 0
        else:
            if not stat.S_ISLNK(mode): break
            data = os.readlink(e.path).encode('utf-8', 'surrogateescape')
            if len(data) != csize: break
            method, crc, usize = 0, zlib.crc32(data), csize
        h = header(e, method, crc, csize, usize, usize >= L32)   # as this pack writes it (csize < usize past 4 GB)
        if len(h[0]) != hlen or (kind != 'f' and x != h[0].hex()) or off + hlen + csize > cd or os.pread(fd, hlen + len(data), off) != h[0] + data: break
        keep.append((e, off, h, method, crc, csize, usize, kind, x)); pos = off + hlen + csize
    return keep, pos


def main():
    ap = argparse.ArgumentParser(description='Pack an IPA (zip) from source folders mapped to archive paths, in parallel')
    ap.add_argument('out'); ap.add_argument('maps', nargs='+', metavar='archive_path=folder')
    ap.add_argument('--store', default='', help='suffixes stored without compressing, separated by ":"')
    ap.add_argument('--skip', action='append', default=[], help='an archive path left out of the folder walk that would add it')
    ap.add_argument('--skip-suffix', action='append', default=[], help='files whose names end so are left out of every folder walk')
    ap.add_argument('--no-reuse', action='store_true', help='pack every file again, without copying from the old IPA')
    a = ap.parse_args()
    maps = []
    for m in a.maps:
        arc, sep, src = m.partition('=')
        if not sep or not arc.strip('/') or not os.path.isdir(src): sys.exit(f'[RED] pack_ipa: not <archive path>=<folder>: {m}')
        maps.append((arc.strip('/'), src))
    store = tuple(s.lower() for s in a.store.split(':') if s)
    t0 = time.time()
    es = entries(order(maps), {s.strip('/') for s in a.skip}, tuple(a.skip_suffix))
    total = sum(e.st.st_size for e in es if e.st and stat.S_ISREG(e.st.st_mode))
    print(f'pack: {len(es)} entries, {total} bytes', flush=True)
    flags = [not e.name.lower().endswith(store) if store else True for e in es]   # each file's deflate flag
    part = a.out + '.partial'
    old, idx = (None, None) if a.no_reuse else load_index(a.out) or (None, None)   # the old IPA stays open, and readable, until the new one replaces it
    size = old and os.fstat(old.fileno()).st_size
    keep, kept = prefix(es, flags, idx['entries'], old, idx['cd']) if old else ([], 0)
    rows = {r[0]: r[5] for r in idx['entries'] if isinstance(r, list) and len(r) == 6 and r[1] == 'f' and isinstance(r[0], str)} if old else {}
    if os.path.lexists(part): os.unlink(part)
    if kept and not clone(a.out, part): keep, kept = [], 0   # no clone: everything is written, files still copied compressed
    try:
        z = Zip(part, kept)
    except BaseException:
        if os.path.lexists(part): os.unlink(part)
        if old: old.close()
        raise
    try:
        for k in keep: z.kept(k)
        pend, inflight = collections.deque(), 0
        def one():   # write the oldest pending entry
            e, fut, deflate = pend.popleft()
            if fut is None: z.other(e); return 0
            if fut is True: z.stream(e, deflate); return 0   # later pool jobs run while this file is streamed
            if isinstance(fut, list): z.reuse(e, fut, old); return 0
            method, crc, data = fut.result(); z.put(e, method, crc, data, e.st.st_size, deflate); return e.st.st_size
        with cf.ThreadPoolExecutor(os.cpu_count()) as pool:
            for e, deflate in zip(es[len(keep):], flags[len(keep):]):
                if not (e.st and stat.S_ISREG(e.st.st_mode)): pend.append((e, None, None)); continue   # folders and symlinks keep their place in the queue
                r = rows.get(e.name)
                if r is not None and match(r, e, deflate, old, size): pend.append((e, r, deflate)); continue   # copied in its place in the queue, by the writer
                if e.st.st_size > BIG:
                    pend.append((e, True, deflate)); continue
                while pend and (len(pend) >= QUEUE or inflight + e.st.st_size > WINDOW): inflight -= one()
                pend.append((e, pool.submit(load, e.path, deflate), deflate)); inflight += e.st.st_size
            while pend: inflight -= one()
        z.close()
    except BaseException:
        z.f.close(); os.unlink(part)
        if old: old.close()
        raise
    os.replace(part, a.out)
    if old: old.close()
    st = os.stat(a.out)
    try:   # the index only after the rename: an IPA it does not describe (size, time) makes it ignored
        blob = json.dumps({'version': IDX_VERSION, 'ipa': [st.st_size, st.st_mtime_ns], 'level': LEVEL, 'cd': z.cd_off, 'entries': z.rows})
        with open(a.out + '.idx.partial', 'w') as f: f.write(blob)
        os.replace(a.out + '.idx.partial', a.out + '.idx'); z.written += len(blob)
    except OSError as x: print(f'[RED] pack_ipa: index not written, the next pack packs every file again: {x}', flush=True)
    s, dt = z.stats, time.time() - t0
    # kept_bytes: the archive's leading bytes kept in place from the old IPA by the clone (not written); written_bytes: every byte this pack wrote (entries, header patches,
    # the central directory, the index). The archive size is logical; written_bytes also counts overwritten and discarded bytes
    print(f'packed: {len(es)} entries, stored {s["stored"] / 2**30:.2f} GB, deflated {s["deflated"] / 2**30:.2f} GB, archive {st.st_size / 2**30:.2f} GB, '
          f'kept {kept / 2**30:.2f} GB in place (clone), reused {s["reused"]} entries ({s["copied"] / 2**30:.2f} GB copied) in {dt:.0f} s ({total / max(dt, 1e-3) / 2**20:.0f} MB/s), '
          f'kept_bytes={kept} written_bytes={z.written}', flush=True)


if __name__ == '__main__': main()
