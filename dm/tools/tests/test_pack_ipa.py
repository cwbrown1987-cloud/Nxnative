"""pack_ipa.py's repeat packs: the leading entries kept in an APFS clone of the old IPA, the files after them copied compressed through <out>.idx, all matching a fresh pack;
a stale or broken index is ignored. Needs TMPDIR on APFS (the clone)."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile

REPO = Path(__file__).resolve().parents[3]
PACK = REPO / 'dm/ios/tools/pack_ipa.py'
# Loads the module and runs main(), with BIG and CHUNK small enough for the streamed path on small files, after the given statements (monkeypatches)
LAUNCH = ('import importlib.util, sys\n'
          'spec = importlib.util.spec_from_file_location("pack_ipa", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n'
          'm.BIG, m.CHUNK = int(sys.argv[2]), int(sys.argv[3]); sys.argv = [sys.argv[1]] + sys.argv[4:]\n')
Z64 = 'header = m.header; m.header = lambda *args: header(*args[:5], True)\n'   # every local header with a zip64 extra
NO_CLONE = 'm.clone = lambda src, dst: False\n'


class PackIpa(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.tmp)
        self.app, self.rom = self.tmp / 'app', self.tmp / 'romfs'
        (self.app / 'sub').mkdir(parents=True); (self.rom / 'déjà').mkdir(parents=True)
        (self.app / 'exe').write_bytes(b'\x7fELF' + b'code' * 3000); os.chmod(self.app / 'exe', 0o755)
        (self.app / 'sub/info.plist').write_text('<plist>' + 'x' * 5000 + '</plist>')
        os.symlink('info.plist', self.app / 'sub/link')
        (self.rom / 'random.bin').write_bytes(os.urandom(30000))
        (self.rom / 'text.txt').write_text('hello world ' * 4000)
        (self.rom / 'déjà/empty').write_bytes(b'')
        (self.rom / 'gone.dat').write_bytes(b'abc' * 2000)
        self.maps = [f'Payload/DmIOS.app={self.app}', f'Payload/DmIOS.app/romfs={self.rom}']

    def pack(self, out, *opts, big=None, chunk=16 << 20, pre=''):
        args = [str(out), *opts, *self.maps]
        if big is None and not pre: cmd = [sys.executable, str(PACK), *args]
        else: cmd = [sys.executable, '-c', LAUNCH + pre + 'm.main()\n', str(PACK), str(big or 256 << 20), str(chunk), *args]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30)

    def ok(self, out, *opts, **kw):   # the reused files; self.kept, self.written: the summary's byte counters
        p = self.pack(out, *opts, **kw); self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        lines = p.stdout.splitlines(); self.assertTrue(lines[0].startswith('pack: '), lines)
        self.assertFalse(Path(str(out) + '.partial').exists())
        self.kept = int(lines[-1].split('kept_bytes=')[1].split()[0]); self.written = int(lines[-1].split('written_bytes=')[1].split()[0])
        return int(lines[-1].split('reused ')[1].split()[0])

    def same(self, a, b):   # names, bytes, CRC, modes, times and method as a fresh pack writes them
        with zipfile.ZipFile(a) as za, zipfile.ZipFile(b) as zb:
            self.assertIsNone(za.testzip())
            self.assertEqual(za.namelist(), zb.namelist())
            for ia, ib in zip(za.infolist(), zb.infolist()):
                self.assertEqual((ia.CRC, ia.external_attr, ia.date_time, ia.compress_type, ia.file_size, ia.flag_bits, ia.header_offset),
                                 (ib.CRC, ib.external_attr, ib.date_time, ib.compress_type, ib.file_size, ib.flag_bits, ib.header_offset), ia.filename)
                self.assertEqual(za.read(ia), zb.read(ib), ia.filename)
        self.assertEqual(Path(a).read_bytes(), Path(b).read_bytes())

    def offset(self, ipa, name):
        with zipfile.ZipFile(ipa) as z: return z.getinfo(name).header_offset

    def fresh(self, out, *opts, **kw):
        f = self.tmp / 'fresh.ipa'; self.ok(f, '--no-reuse', *opts, **kw); self.assertEqual(self.kept, 0); self.same(out, f)

    def test_unchanged_clone(self):
        out = self.tmp / 'a.ipa'
        self.assertEqual(self.ok(out), 0); full = self.written
        self.assertEqual(self.ok(out), 6)
        cd = json.loads((self.tmp / 'a.ipa.idx').read_text())['cd']
        self.assertEqual(self.kept, cd); self.assertLess(self.written, full - cd + 1000)   # only the central directory and the index written
        self.fresh(out)

    def test_app_change_keeps_romfs(self):
        out = self.tmp / 'a.ipa'
        self.ok(out); (self.app / 'exe').write_bytes(b'\x7fELF' + b'new!' * 3000)
        self.assertEqual(self.ok(out), 5)
        self.assertEqual(self.kept, self.offset(out, 'Payload/DmIOS.app/exe'))   # the RomFS leads the archive, all of it kept
        self.assertGreater(self.kept, self.offset(out, 'Payload/DmIOS.app/romfs/text.txt'))
        self.fresh(out)

    def test_app_folder_change_keeps_romfs(self):
        out = self.tmp / 'a.ipa'
        self.ok(out); replacement = self.app / 'new-exe'; replacement.write_bytes(b'new code' * 1500)
        os.replace(replacement, self.app / 'exe'); t = time.time() - 7200; os.utime(self.app, (t, t))
        self.assertEqual(self.ok(out), 5)
        self.assertEqual(self.kept, self.offset(out, 'Payload/DmIOS.app/'))
        self.assertGreater(self.kept, self.offset(out, 'Payload/DmIOS.app/romfs/text.txt'))
        self.fresh(out)

    def test_romfs_first_change(self):
        out = self.tmp / 'a.ipa'
        self.ok(out); (self.rom / 'déjà/empty').write_bytes(b'now something')
        self.assertEqual(self.ok(out), 5)
        self.assertEqual(self.kept, self.offset(out, 'Payload/DmIOS.app/romfs/déjà/empty'))
        self.fresh(out)

    def test_order_and_parent_ownership(self):
        msl, aoc, pso = self.tmp / 'msl', self.tmp / 'aoc', self.tmp / 'pso'
        (msl / 'lib').mkdir(parents=True); (msl / 'lib/a.metallib').write_bytes(b'm' * 100); (aoc / '1').mkdir(parents=True); (aoc / '1/x').write_bytes(b'x')
        pso.mkdir(); (pso / 'archive').write_bytes(b'pso')
        (self.app / 'msl').mkdir(); (self.app / 'msl/own.txt').write_text('own')
        old = time.time() - 86400 * 3
        for d in (self.app / 'msl', self.app): os.utime(d, (old, old))
        old += 86400
        self.maps = [f'Payload/DmIOS.app={self.app}', f'Payload/DmIOS.app/msl/lib={msl / "lib"}', f'Payload/DmIOS.app/romfs={self.rom}', f'Payload/DmIOS.app/aoc={aoc}', f'Payload/DmIOS.app/pso={pso}']
        out = self.tmp / 'a.ipa'; self.ok(out)
        with zipfile.ZipFile(out) as z:
            names = z.namelist(); self.assertEqual(len(names), len(set(names)))
            self.assertEqual(names[:2], ['Payload/', 'Payload/DmIOS.app/romfs/'])
            self.assertLess(names.index('Payload/DmIOS.app/romfs/text.txt'), names.index('Payload/DmIOS.app/aoc/'))
            self.assertLess(names.index('Payload/DmIOS.app/aoc/1/x'), names.index('Payload/DmIOS.app/pso/'))
            self.assertLess(names.index('Payload/DmIOS.app/pso/archive'), names.index('Payload/DmIOS.app/msl/'))
            self.assertEqual(names.index('Payload/DmIOS.app/msl/') + 1, names.index('Payload/DmIOS.app/msl/lib/'))
            self.assertLess(names.index('Payload/DmIOS.app/msl/lib/a.metallib'), names.index('Payload/DmIOS.app/exe'))
            self.assertIn('Payload/DmIOS.app/msl/own.txt', names)
            self.assertEqual(z.getinfo('Payload/').date_time, (1980, 1, 1, 0, 0, 0))
            for name, src in (('Payload/DmIOS.app/', self.app), ('Payload/DmIOS.app/msl/', self.app / 'msl')):   # the owner's time and mode
                info = z.getinfo(name); st = src.stat()
                self.assertEqual(info.date_time[:5], time.localtime(st.st_mtime)[:5], name); self.assertEqual(info.external_attr >> 16, st.st_mode, name)
        self.assertEqual(self.ok(out), 10); self.assertGreater(self.kept, 0); self.fresh(out)
        self.maps.reverse(); self.ok(out); self.assertEqual(self.kept, json.loads((self.tmp / 'a.ipa.idx').read_text())['cd'])   # the command line's order does not matter
        self.maps.append(f'Payload/DmIOS.app={self.app}')
        p = self.pack(out); self.assertNotEqual(p.returncode, 0); self.assertIn('twice in the archive', p.stderr)

    def test_nested_romfs_mapping_precedes_shaders(self):
        extra, msl = self.tmp / 'extra', self.tmp / 'msl'
        extra.mkdir(); msl.mkdir(); (extra / 'child').write_bytes(b'child'); (msl / 'shader').write_bytes(b'msl')
        self.maps += [f'Payload/DmIOS.app/msl={msl}', f'Payload/DmIOS.app/romfs/deep={extra}']
        out = self.tmp / 'a.ipa'; self.ok(out)
        self.assertLess(self.offset(out, 'Payload/DmIOS.app/romfs/deep/child'), self.offset(out, 'Payload/DmIOS.app/romfs/'))
        self.assertLess(self.offset(out, 'Payload/DmIOS.app/romfs/text.txt'), self.offset(out, 'Payload/DmIOS.app/msl/'))
        self.assertEqual(self.ok(out), 8); self.assertGreater(self.kept, 0); self.fresh(out)

    def test_clone_failure_fallback(self):
        out = self.tmp / 'a.ipa'
        self.ok(out); self.assertEqual(self.ok(out, pre=NO_CLONE), 6); self.assertEqual(self.kept, 0)
        self.fresh(out)

    def test_symlink_and_folder_header_changes(self):
        out = self.tmp / 'a.ipa'
        self.ok(out); os.unlink(self.app / 'sub/link'); os.symlink('../exe', self.app / 'sub/link')
        self.assertEqual(self.ok(out), 6); self.assertEqual(self.kept, self.offset(out, 'Payload/DmIOS.app/sub/link')); self.fresh(out)
        t = time.time() - 7200; os.utime(self.app / 'sub', (t, t))
        self.assertEqual(self.ok(out), 6); self.assertEqual(self.kept, self.offset(out, 'Payload/DmIOS.app/sub/')); self.fresh(out)
        os.chmod(self.app / 'sub', 0o700)   # the mode is only in the central directory, which is written again
        self.assertEqual(self.ok(out), 6); self.assertGreater(self.kept, self.offset(out, 'Payload/DmIOS.app/sub/link')); self.fresh(out)

    def test_edits_adds_deletes(self):
        out = self.tmp / 'a.ipa'
        self.assertEqual(self.ok(out), 0)
        self.assertEqual(self.ok(out), 6)   # every regular file again
        (self.rom / 'text.txt').write_text('changed ' * 3000); (self.rom / 'gone.dat').unlink(); (self.rom / 'new.bin').write_bytes(b'n' * 9000)
        (self.app / 'sub/info.plist').write_text('<plist>' + 'y' * 5000 + '</plist>')   # the same size
        self.assertEqual(self.ok(out), 3)
        self.fresh(out)
        with zipfile.ZipFile(out) as z: self.assertEqual(z.read('Payload/DmIOS.app/sub/info.plist'), (self.app / 'sub/info.plist').read_bytes())

    def test_store_flag_change(self):
        out = self.tmp / 'a.ipa'
        self.ok(out); self.assertEqual(self.ok(out, '--store', '.TXT'), 5)
        self.fresh(out, '--store', '.txt')
        with zipfile.ZipFile(out) as z: self.assertEqual(z.getinfo('Payload/DmIOS.app/romfs/text.txt').compress_type, zipfile.ZIP_STORED)

    def test_replaced_ipa_stale_index(self):
        out, other = self.tmp / 'a.ipa', self.tmp / 'b.ipa'
        self.ok(out); (self.rom / 'text.txt').write_text('other ' * 100); self.ok(other, '--no-reuse')
        idx = (out.parent / 'a.ipa.idx').read_text(); os.replace(other, out); (out.parent / 'a.ipa.idx').write_text(idx)
        self.assertEqual(self.ok(out), 0); self.assertEqual(self.kept, 0)
        self.fresh(out)

    def test_missing_and_malformed_index(self):
        out = self.tmp / 'a.ipa'; idxp = self.tmp / 'a.ipa.idx'
        self.ok(out)
        idxp.unlink(); self.assertEqual(self.ok(out), 0); self.fresh(out)
        idxp.write_text('{not json'); self.assertEqual(self.ok(out), 0); self.fresh(out)
        self.ok(out); idx = json.loads(idxp.read_text()); idx['version'] = 1; idxp.write_text(json.dumps(idx))
        self.assertEqual(self.ok(out), 0); self.fresh(out)
        self.ok(out); idx = json.loads(idxp.read_text()); rows = {r[0]: r for r in idx['entries']}
        rows['Payload/DmIOS.app/exe'][5][8] += 1                         # offset off by one: its local header does not end there
        rows['Payload/DmIOS.app/romfs/text.txt'][5][8] = 1 << 40         # past the end
        rows['Payload/DmIOS.app/romfs/random.bin'][5] = ['x'] * 9        # not numbers
        rows['Payload/DmIOS.app/romfs/gone.dat'][5][5] = 12              # an unknown method
        rows['Payload/DmIOS.app/sub/info.plist'][5][7] += 1             # valid header, wrong compressed size
        idxp.write_text(json.dumps(idx))
        self.assertEqual(self.ok(out), 1); self.assertEqual(self.kept, self.offset(out, 'Payload/DmIOS.app/romfs/gone.dat')); self.fresh(out)
        self.ok(out); idx = json.loads(idxp.read_text()); rows = {r[0]: r for r in idx['entries']}
        h = rows['Payload/DmIOS.app/romfs/déjà/'][5]; rows['Payload/DmIOS.app/romfs/déjà/'][5] = h[:-2] + ('00' if h[-2:] != '00' else '01')   # a folder's recorded header
        idxp.write_text(json.dumps(idx))
        self.assertEqual(self.ok(out), 6); self.assertEqual(self.kept, self.offset(out, 'Payload/DmIOS.app/romfs/déjà/')); self.fresh(out)
        self.ok(out); idx = json.loads(idxp.read_text()); bad = idx['entries'][1][0]; idx['entries'][1][2] += 1; idxp.write_text(json.dumps(idx))   # the second entry not right after the first
        self.assertEqual(self.ok(out), 6); self.assertEqual(self.kept, self.offset(out, bad)); self.fresh(out)

    def test_streamed_reuse(self):
        out = self.tmp / 'a.ipa'
        self.ok(out, big=1024, chunk=4096)
        self.assertEqual(self.ok(out, big=1024, chunk=4096), 6)
        (self.rom / 'random.bin').write_bytes(os.urandom(30000))
        self.assertEqual(self.ok(out, big=1024, chunk=4096), 5); self.assertGreater(self.kept, 0)
        self.fresh(out, big=1024, chunk=4096)
        self.assertEqual(self.ok(out), 6)   # entries streamed before are copied by the pool path's writer too
        self.fresh(out)

    def test_pool_works_past_streamed_file(self):
        pre = ('import threading\n'
               'ready = threading.Event(); load = m.load; stream = m.Zip.stream\n'
               'def later(path, deflate):\n'
               '    if path.endswith("/exe"): ready.set()\n'
               '    return load(path, deflate)\n'
               'def overlap(self, e, deflate, flag=None):\n'
               '    assert ready.wait(5), "the app was not submitted before the RomFS stream"\n'
               '    return stream(self, e, deflate, flag)\n'
               'm.load = later; m.Zip.stream = overlap\n')
        out = self.tmp / 'a.ipa'; self.ok(out, big=40000, pre=pre); self.fresh(out, big=40000)

    def test_zip64_local_header_reuse(self):
        out = self.tmp / 'a.ipa'
        self.ok(out, big=1 << 20, pre=Z64)
        with zipfile.ZipFile(out) as z: self.assertIsNone(z.testzip())
        self.assertEqual(self.ok(out, big=1 << 20, pre=Z64), 6); self.assertEqual(self.kept, json.loads((self.tmp / 'a.ipa.idx').read_text())['cd'])   # zip64 headers kept as they are
        self.assertEqual(self.ok(out), 6); self.assertEqual(self.kept, 0)   # without zip64 extras no header is the same
        self.fresh(out)

    def test_failure_keeps_old_ipa_and_index(self):
        out = self.tmp / 'a.ipa'; idxp = self.tmp / 'a.ipa.idx'
        self.ok(out); before, idx = out.read_bytes(), idxp.read_text()
        for bad in (self.rom / 'locked.bin', self.app / 'locked.bin'):   # the second after a long kept run, in the clone
            bad.write_bytes(b'z' * 100); os.chmod(bad, 0)
            try:
                p = self.pack(out); self.assertNotEqual(p.returncode, 0)
            finally: os.chmod(bad, 0o644); bad.unlink()
            self.assertEqual(out.read_bytes(), before); self.assertEqual(idxp.read_text(), idx); self.assertFalse((self.tmp / 'a.ipa.partial').exists())
        self.assertEqual(self.ok(out), 6)


if __name__ == '__main__': unittest.main()
