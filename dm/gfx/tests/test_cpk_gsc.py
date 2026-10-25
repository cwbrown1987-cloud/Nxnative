"""Synthetic GSC and CPK integration fixtures; no game files or compilers needed."""
from pathlib import Path
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import cpk
os.environ.setdefault('DM_GAME', '01006BB00C6F0000')
import shader_split as split


def table(columns, rows):
    strings = bytearray(b'table\0'); offsets = {'table': 0}
    def string(s):
        if s not in offsets:
            offsets[s] = len(strings); strings.extend(s.encode() + b'\0')
        return offsets[s]
    fmt = {4:'I', 6:'Q', 10:'I'}
    def pack(kind, v):
        return struct.pack('>' + fmt[kind], string(v) if kind == 10 else v)
    cols = bytearray(); body = bytearray()
    for name, storage, kind, constant in columns:
        cols.extend(struct.pack('>BI', storage | kind, string(name)))
        if storage == 0x30: cols.extend(pack(kind, constant))
    width = sum(struct.calcsize('>' + fmt[kind]) for _, storage, kind, _ in columns if storage == 0x50)
    for row in rows:
        for name, storage, kind, _ in columns:
            if storage == 0x50: body.extend(pack(kind, row[name]))
    ro = 32 + len(cols); so = ro + len(body); bo = so + len(strings)
    return b'@UTF' + struct.pack('>5I2HI', bo - 8, ro - 8, so - 8, bo - 8, 0, len(columns), width, len(rows)) + cols + body + strings


def packet(magic, t):
    return magic + struct.pack('<IQ', 255, len(t)) + t


def layla(bits, decoded_size, prefix=bytes(range(256))):
    bits += '0' * (-len(bits) % 8)
    stream = bytes(int(bits[i:i+8], 2) for i in range(0, len(bits), 8))[::-1]
    return b'CRILAYLA' + struct.pack('<II', decoded_size, len(stream)) + stream + prefix


def gsc(stages=('vs', 'ps')):
    data = bytearray(32); data[:4] = b'GFS0'; data[16:20] = b'GSC0'
    for i, stage in enumerate(stages):
        ctl = bytearray(0x850); ctl[:4] = split.CTL_MAGIC
        struct.pack_into('<I', ctl, 0x20, len(ctl))
        struct.pack_into('<I', ctl, 0x704, 0x100)
        code = bytearray(0x100); code[:4] = split.GFX_MAGIC
        struct.pack_into('<I', code, 0x30, 0x0461 if stage == 'vs' else 0x1461)
        # Vary the metadata length as the real HHNEEDLE records do.
        payload = b'metadata' * (i + 1) + ctl + code
        data.extend(b'HHNEEDLE' + struct.pack('>I', 4 + len(payload)) + payload)
    return bytes(data)


class GscTests(unittest.TestCase):
    def test_cpk_stored_and_compressed_cache(self):
        payload = gsc()
        hdr = table([(n,0x50,6,None) for n in ('TocOffset','ContentOffset','Files')],
                    [{'TocOffset':0x800,'ContentOffset':0x1000,'Files':1}])
        for compressed in (False, True):
            with self.subTest(compressed=compressed):
                data = layla(''.join('0'+f'{b:08b}' for b in payload[256:][::-1]), len(payload)-256, payload[:256]) if compressed else payload
                toc = table([('DirName',0x50,10,None),('FileName',0x50,10,None),('FileOffset',0x50,6,None),
                             ('FileSize',0x50,4,None),('ExtractSize',0x50,4,None)],
                            [{'DirName':'BASE','FileName':'cache.GSC','FileOffset':0x800,'FileSize':len(data),'ExtractSize':len(payload)}])
                archive = bytearray(0x1000); h=packet(b'CPK ',hdr); t=packet(b'TOC ',toc)
                archive[:len(h)] = h; archive[0x800:0x800+len(t)] = t; archive.extend(data)
                with tempfile.TemporaryDirectory() as tmp:
                    path = Path(tmp)/'cache.cpk'; path.write_bytes(archive)
                    jobs, taken = split.cpk_jobs([(str(path),'cache.cpk')])
                    self.assertEqual(taken, {str(path)})
                    result = split.scan_file(jobs[0])
                    self.assertEqual(len(result[1]), 2)

    def test_inline_nvn_programs_and_truncated_false_positive(self):
        d = gsc()
        records = split.raw_nvn_shaders(d, 'main')
        self.assertEqual([r[1] for r in records], ['vs','ps'])
        self.assertTrue(all('#NVN@' in r[0] for r in records))
        self.assertEqual(split.raw_nvn_shaders(split.CTL_MAGIC + bytes(40),'main'), [])
        bad = bytearray(d); c = bad.find(split.CTL_MAGIC)
        struct.pack_into('<I', bad, c + 0x704, len(bad) * 10)
        self.assertEqual(len(split.raw_nvn_shaders(bad,'main')), 1)

    def test_stage_and_short_control_hash(self):
        records=split.gsc_shaders(gsc(),'synthetic')
        self.assertEqual([r[1] for r in records],['vs','ps'])
        self.assertTrue(all(len(r[2])==0x850 for r in records))
        self.assertTrue(all(split.ctl_len(r[2])==0x850 for r in records))
        keys=split.uniq_keys(records)
        pairs, cover=split.separable_pairs(keys)
        # No fragment varying inputs in this fixture; a real GSC is covered by its input union.
        self.assertEqual(pairs,set())

    def test_gsc_and_inline_stages_use_the_varying_cover(self):
        data = bytearray(gsc())
        pixel = data.find(split.CTL_MAGIC, data.find(split.CTL_MAGIC)+1) + 0x850
        struct.pack_into('<I', data, pixel+0x48, 1)  # fragment location 0 is read
        for reader in (split.gsc_shaders, split.raw_nvn_shaders):
            with self.subTest(reader=reader.__name__):
                keys = split.uniq_keys(reader(bytes(data), 'synthetic'))
                vs = next(k for k,v in keys.items() if v[1]=='vs')
                ps = next(k for k,v in keys.items() if v[1]=='ps')
                pairs, cover = split.separable_pairs(keys)
                self.assertEqual(cover, [ps])
                self.assertEqual(pairs, {(vs, ps)})

    def test_invalid_record_lengths(self):
        d=bytearray(gsc()); struct.pack_into('>I',d,40,len(d)+1)
        with self.assertRaises(SystemExit): split.gsc_shaders(d,'synthetic')

    def test_missing_control_and_code_truncation(self):
        d=gsc(('vs',))
        for bad in (d.replace(split.CTL_MAGIC,b'bad!'),d[:-1]):
            with self.assertRaises(SystemExit): split.gsc_shaders(bad,'synthetic')

    def test_stage_magic_rejected(self):
        d=gsc(('vs',)).replace(split.GFX_MAGIC,b'bad!')
        with self.assertRaises(SystemExit): split.gsc_shaders(d,'synthetic')


if __name__=='__main__': unittest.main()
