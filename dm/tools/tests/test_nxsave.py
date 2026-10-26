"""dm/tools/nxsave.py reads the save sync's archives (dm/host/savesync_apple.m): header and entries, unpacking with guest names, and refusing a damaged file or a path that leaves the folder."""
import hashlib
import importlib.util
import os
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('nxsave', ROOT / 'dm/tools/nxsave.py')
nxsave = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nxsave)


def entry(t, rel, guest='', data=b''):
    e = t.encode() + struct.pack('<H', len(rel)) + rel.encode() + struct.pack('<H', len(guest)) + guest.encode()
    return e + struct.pack('<Q', len(data)) + data if t == 'f' else e


def archive(body, digest=None):
    z = zlib.compressobj(wbits=-15)
    return f"NXSAVE 1\ndigest {digest or hashlib.sha256(body).hexdigest()}\ndevice Mac\ntime 1700000000\n\n".encode() + z.compress(body) + z.flush()


class NxSaveTests(unittest.TestCase):
    def write(self, tmp, raw):
        p = Path(tmp) / 'save.nxsave'; p.write_bytes(raw); return p

    def test_reads_and_unpacks(self):
        body = entry('f', '.dm-case-1', 'a.dat', b'lower') + entry('f', 'A.DAT', '', b'upper') + entry('d', 'sub') + entry('f', 'sub/B.DAT', '', b'b')
        with tempfile.TemporaryDirectory() as tmp:
            head, entries = nxsave.read(self.write(tmp, archive(body)))
            self.assertEqual(head['device'], 'Mac')
            self.assertEqual([(t, r) for t, r, _, _ in entries], [('f', '.dm-case-1'), ('f', 'A.DAT'), ('d', 'sub'), ('f', 'sub/B.DAT')])
            out = Path(tmp) / 'out'
            nxsave.unpack(self.write(tmp, archive(body)), out)
            self.assertEqual((out / 'sub/B.DAT').read_bytes(), b'b')
            if hasattr(os, 'getxattr'):
                self.assertEqual(os.getxattr(out / '.dm-case-1', nxsave.GUEST_NAME), b'a.dat')

    def test_refuses_damaged_and_escaping_archives(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                nxsave.read(self.write(tmp, archive(entry('f', 'A.DAT', '', b'x'), digest='0' * 64)))
            for rel in ('../x', '/x', 'a//x'):
                with self.subTest(rel=rel), self.assertRaises(ValueError):
                    nxsave.read(self.write(tmp, archive(entry('f', rel, '', b'x'))))

    def test_empty_save(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(nxsave.read(self.write(tmp, archive(b'')))[1], [])


if __name__ == '__main__':
    unittest.main()
