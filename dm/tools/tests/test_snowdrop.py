"""Synthetic WEST/BERG fixtures; no game files or shader captures required."""
from pathlib import Path
import struct
import ast
import sys
import tempfile
import unittest
try:
    from compression import zstd
except ImportError:
    from backports import zstd

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'gfx/tools'))
import snowdrop as sd

IDENT = b'massive\0' + bytes(32) + b'ubisoft\0'

def record(size, packed, compressed=False, pages=(), archive=7, offset=56):
    ns = max(1, (max(size, packed).bit_length()+7)//8)
    no = max(1, (offset.bit_length()+7)//8)
    flags = ns-1 | no << 2 | (32 if compressed else 0)
    return (bytes([flags]) + size.to_bytes(ns, 'little')
            + (packed.to_bytes(ns, 'little') if compressed else b'')
            + offset.to_bytes(no, 'little') + struct.pack('<H', archive)
            + b''.join(struct.pack('<H', n) for n in pages))

def tree(parts, name=b'shaders/nvn/test.mcache'):
    return bytes([len(name)]) + name + bytes([65+len(parts)]) + bytes(5) + b''.join(parts) + b'\0'

def toc(nodes, first=7, count=1):
    packed = zstd.compress(nodes)
    return (struct.pack('<4s6I', b'WEST', 22, len(nodes), len(packed), first, count, 0)
            + IDENT + b'\0' + bytes(count*52) + packed + IDENT)

def berg(data):
    return b'BERG' + struct.pack('<I', 22) + IDENT + data

def shader():
    ctl = bytearray(0x880); ctl[:4] = sd.CTL
    struct.pack_into('<I', ctl, 0x20, len(ctl))
    code = bytearray(0x80); code[:4] = bytes.fromhex('78563412')
    struct.pack_into('<I', code, 0x30, 0x461)
    struct.pack_into('<I', ctl, 0x704, len(code))
    return bytes(ctl), bytes(code)

class SnowdropTests(unittest.TestCase):
    def archive(self, index, payload):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        root = Path(tmp.name); (root/'sdf.sdftoc').write_bytes(index)
        (root/'sdf_D_0007.sdfdata').write_bytes(berg(payload))
        return sd.Archive(root/'sdf.sdftoc')

    def test_raw_and_multipart(self):
        a = self.archive(toc(tree([record(3,3),record(2,2,offset=59)])),b'abcde')
        self.assertEqual(a.read(a.entries[0]),b'abcde')

    def test_independent_archive_layers(self):
        index=toc(tree([record(3,3)]))
        base=self.archive(index,b'old'); update=self.archive(index,b'new')
        self.assertEqual(base.read(base.entries[0]),b'old')
        self.assertEqual(update.read(update.entries[0]),b'new')

    def test_compressed_page_and_raw_sentinel(self):
        tail=b'last page'*100; packed=zstd.compress(tail)
        raw=b'x'*65536
        a=self.archive(toc(tree([record(len(raw)+len(tail),len(raw)+len(packed),True,(0,len(packed)))])),raw+packed)
        self.assertEqual(a.read(a.entries[0]),raw+tail)

    def test_single_compressed_page(self):
        raw=b'payload'*200; packed=zstd.compress(raw)
        a=self.archive(toc(tree([record(len(raw),len(packed),True)])),packed)
        self.assertEqual(a.read(a.entries[0]),raw)

    def test_branch_and_prefix(self):
        # Two records share the literal prefix. The split offsets are absolute.
        prefix=b'shaders/'; left=tree([record(1,1)],b'nvn/a')[:-1]
        right=tree([record(1,1,offset=57)],b'nvn/b')
        split=1+len(prefix)
        nodes=bytes([len(prefix)])+prefix+b'_' + struct.pack('<I',split+5+len(left))+left+right
        a=self.archive(toc(nodes),b'ab')
        self.assertEqual([e.name for e in a.entries],['shaders/nvn/a','shaders/nvn/b'])
        self.assertEqual([a.read(e) for e in a.entries],[b'a',b'b'])

    def test_invalid_index(self):
        valid=toc(tree([record(1,1)]))
        cases=[valid[:-1],b'FAIL'+valid[4:],valid[:4]+struct.pack('<I',23)+valid[8:],
               toc(b'_'+bytes(4)),toc(tree([record(1,1,archive=8)])),
               toc(tree([record(1,1,offset=55)])),
               toc(tree([record(65537,3,True,(1,1))]))]
        for data in cases:
            with self.subTest(size=len(data)),self.assertRaises(sd.FormatError):sd.directory(data)

    def test_missing_truncated_and_invalid_archive(self):
        a=self.archive(toc(tree([record(4,4)])),b'123')
        with self.assertRaises(sd.FormatError):a.read(a.entries[0])
        path=a.files[7];path.write_bytes(b'FAIL'+berg(b'1234')[4:])
        with self.assertRaises(sd.FormatError):a.read(a.entries[0])
        path.unlink()
        a=sd.Archive(a.toc)
        with self.assertRaises(sd.FormatError):a.read(a.entries[0])

    def test_exact_compression_boundaries(self):
        data=zstd.compress(b'abcd')
        for packed,size in [(data[:-1],4),(data+b'junk',4),(data,3),(data,5)]:
            with self.subTest(size=size),self.assertRaises(sd.FormatError):sd.zstd_exact(packed,size)

    def test_dual_stage_cache_vertex_gets_cross_program_varyings(self):
        source=Path(__file__).resolve().parents[2]/'gfx/tools/shader_split.py'
        module=ast.parse(source.read_text())
        nodes=[n for n in module.body if isinstance(n,ast.FunctionDef) and n.name in ('ps_inputs','separable_pairs')
               or isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='SINGLE_STAGE' for t in n.targets)]
        scope={'struct':struct}; exec(compile(ast.Module(body=nodes,type_ignores=[]),str(source),'exec'),scope)
        ctl,vs=shader(); ps=bytearray(vs); ps[0x48+5]=1
        keys={'vertex':('cache#MCACHE@program#var','vs',ctl,vs),
              'pixel':('another cache','ps',ctl,bytes(ps)),
              'ordinary':('BNSH#var','vs',ctl,vs)}
        pairs,cover=scope['separable_pairs'](keys)
        self.assertEqual(pairs,{('vertex','pixel')})
        self.assertEqual(cover,['pixel'])

    def test_cache_wrapper_and_lengths(self):
        ctl,code=shader();body=sd.CACHE+bytes(4)+struct.pack('<I',1)+struct.pack('<I',len(ctl)+len(code))+ctl+code+sd.CACHE
        self.assertEqual(sd.cache_shaders(body),[(ctl,code)])
        packed=zstd.compress(body)
        wrapper=sd.CACHE+bytes(8)+struct.pack('<2I',len(body),len(packed))+packed
        self.assertEqual(sd.cache_shaders(wrapper),[(ctl,code)])
        for bad in [body[:-1],body[:12]+struct.pack('<I',1)+body[16:],wrapper+b'x']:
            with self.assertRaises(sd.FormatError):sd.cache_shaders(bad)

if __name__=='__main__':unittest.main()
