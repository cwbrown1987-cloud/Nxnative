"""Synthetic data only: no game files or generated resource tables are bundled."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

spec = importlib.util.spec_from_file_location('overlay', Path(__file__).parents[1] / 'botw_model_heap_overlay.py')
overlay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(overlay)


class ModelHeapOverlayTests(unittest.TestCase):
    def test_yaz0_literal_roundtrip(self):
        for size in (0, 1, 7, 8, 9, 255, 4096):
            data = bytes(i % 256 for i in range(size))
            self.assertEqual(overlay.yaz0_decode(overlay.yaz0_store(data)), data)

    def test_yaz0_overlapping_backreference(self):
        data = b'Yaz0' + struct.pack('>I', 7) + bytes(8) + b'\xe0ABC\x20\x02'
        self.assertEqual(overlay.yaz0_decode(data), b'ABCABCA')

    def test_overlay_changes_only_model_sizes_and_preserves_original(self):
        names = ['Model/Obj_TreeConiferous.bfres', 'Model/Other.bfres',
                 'Model/Other.Tex1.bfres', 'Actor/Other.bin']
        sizes = [0x29e520, 100, 200, 300]
        data = bytearray(b'RSTB' + struct.pack('<II', len(names), len(names)))
        for name, size in zip(names, sizes):
            data.extend(struct.pack('<II', zlib.crc32(name.encode()), size))
        for name, size in zip(names, sizes):
            data.extend(name.encode().ljust(128, b'\0') + struct.pack('<I', size))
        original = overlay.yaz0_store(data)
        with tempfile.TemporaryDirectory() as tmp:
            romfs, out = Path(tmp)/'romfs', Path(tmp)/'overlay'
            table = romfs / overlay.RSTB
            table.parent.mkdir(parents=True)
            table.write_bytes(original)
            (romfs/'Model').mkdir()
            for name in names[:3]:
                (romfs/name.replace('.bfres', '.sbfres')).touch()
            overlay.main([str(romfs), str(out)])
            self.assertEqual(table.read_bytes(), original)
            result = overlay.yaz0_decode((out/overlay.RSTB).read_bytes())
            expected = bytearray(data)
            for i, addition in enumerate([0x80000, 0x10000, 0, 0]):
                struct.pack_into('<I', expected, 12+i*8+4, sizes[i]+addition)
                struct.pack_into('<I', expected, 12+len(names)*8+i*132+128, sizes[i]+addition)
            self.assertEqual(result, expected)
            overlay.main([str(romfs), str(out)])
            self.assertEqual(overlay.yaz0_decode((out/overlay.RSTB).read_bytes()), expected)

    def test_reject_in_place_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit) as exc:
                overlay.main([tmp, tmp])
            self.assertNotEqual(exc.exception.code, 0)


if __name__ == '__main__':
    unittest.main()
