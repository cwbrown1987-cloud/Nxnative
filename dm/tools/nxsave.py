#!/usr/bin/env python3
# A save archive of the host's save sync (dm/host/savesync_apple.m): the file in the sync folder (<folder>/<program ID>/save.nxsave) or a backup (<save directory>.sync/backup/*.nxsave).
# Usage: nxsave.py <file> (prints who wrote it, when, its digest and its files), nxsave.py <file> <new directory> (unpacks it there: copy that over the app's save/ to restore it,
#   with the app closed). Format: a text header ("NXSAVE 1", "digest <sha256 of the body>", "device <name>", "time <unix seconds>", an empty line), then the body compressed with raw
#   deflate; the body is one entry per directory and file in path order: type ('d' / 'f'), u16 path length, path, u16 guest-name length, guest name (the
#   org.d2rmobile.guest-name attribute of a case-collision name), and for a file u64 size and its bytes (little-endian)
import hashlib, os, struct, subprocess, sys, time, zlib

GUEST_NAME = 'org.d2rmobile.guest-name'


def set_guest(path, guest):
    """The guest-name attribute; macOS's Python has no os.setxattr, so its xattr tool writes it there"""
    if sys.platform == 'linux':
        os.setxattr(path, GUEST_NAME, guest.encode(), follow_symlinks=False)
    elif sys.platform == 'darwin':
        subprocess.run(['xattr', '-s', '-w', GUEST_NAME, guest, str(path)], check=True)
    else:
        print(f'{path}: guest name {guest!r} (not set: this system has no extended attributes)', file=sys.stderr)


def get_guest(path):
    if sys.platform == 'linux':
        return os.getxattr(path, GUEST_NAME, follow_symlinks=False).decode()
    r = subprocess.run(['xattr', '-s', '-p', GUEST_NAME, str(path)], capture_output=True, text=True)
    return r.stdout.rstrip('\n') if r.returncode == 0 else None


def read(path):
    """(header dict, [(type, path, guest name, bytes or None)]); ValueError when the file is not a complete archive"""
    raw = open(path, 'rb').read()
    end = raw.find(b'\n\n', 0, 4096)
    if end < 0 or not raw.startswith(b'NXSAVE 1\n'):
        raise ValueError('not a save archive')
    head = dict(l.split(' ', 1) for l in raw[:end].decode().split('\n')[1:] if ' ' in l)
    z = raw[end + 2:]
    body = zlib.decompress(z, -15) if z else b''
    if hashlib.sha256(body).hexdigest() != head.get('digest'):
        raise ValueError('the body does not match its digest (incomplete or damaged)')
    entries, p = [], 0
    while p < len(body):
        t = chr(body[p]); (pl,) = struct.unpack_from('<H', body, p + 1); p += 3
        rel = body[p:p + pl].decode(); p += pl
        (gl,) = struct.unpack_from('<H', body, p); p += 2
        guest = body[p:p + gl].decode(); p += gl
        data = None
        if t == 'f':
            (sz,) = struct.unpack_from('<Q', body, p); p += 8
            data = body[p:p + sz]; p += sz
        if t not in 'df' or rel.startswith('/') or any(c in ('', '.', '..') for c in rel.split('/')):
            raise ValueError(f'bad entry {rel!r}')
        entries.append((t, rel, guest, data))
    return head, entries


def unpack(path, to):
    _, entries = read(path)
    os.mkdir(to)
    for t, rel, guest, data in entries:
        f = os.path.join(to, rel)
        if t == 'd':
            os.makedirs(f, exist_ok=True)
        else:
            with open(f, 'xb') as o:
                o.write(data)
        if guest:
            set_guest(f, guest)


def main(argv):
    if len(argv) not in (2, 3):
        sys.exit(__doc__ or 'usage: nxsave.py <file> [<new directory>]')
    try:
        if len(argv) == 3:
            unpack(argv[1], argv[2]); return
        head, entries = read(argv[1])
    except (OSError, ValueError, zlib.error, struct.error) as e:
        sys.exit(f'nxsave: {argv[1]}: {e}')
    t = int(head.get('time', 0))
    print(f"saved {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(t)) if t else '?'} on {head.get('device', '?')}, digest {head['digest'][:12]}")
    for typ, rel, guest, data in entries:
        print(f"{'' if data is None else len(data):>10}  {rel}{'/' if typ == 'd' else ''}{f'  ({guest})' if guest else ''}")


if __name__ == '__main__':
    main(sys.argv)
