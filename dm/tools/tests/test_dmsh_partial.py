"""Partial-build dependencies and fail-closed varying padding; no toolchain needed."""
import ast
from pathlib import Path
import tempfile
import unittest
import os
import re

SOURCE=Path(__file__).resolve().parents[2]/'gfx/tools/dmsh_build.py'
module=ast.parse(SOURCE.read_text())
nodes=[n for n in module.body if isinstance(n,ast.FunctionDef) and n.name in ('build_keys','vs_pad')]

def functions(**kw):
    scope={'os':os,'re':re,**kw}
    exec(compile(ast.Module(body=nodes,type_ignores=[]),str(SOURCE),'exec'),scope)
    return scope

class PartialTests(unittest.TestCase):
    def test_vertex_adds_pixel_dependency(self):
        f=functions()['build_keys']
        self.assertEqual(f({'v'},{'v','p','other'},{'v':{'p'}}),['p','v'])
        self.assertEqual(f({'p'},{'v','p'},{'v':{'p'}}),['p'])
        self.assertEqual(f(set(),{'v','p'},{'v':{'p'}}),['p','v'])
    def test_missing_partner_is_rejected(self):
        with self.assertRaises(ValueError):functions()['build_keys']({'v'},{'v'},{'v':{'missing'}})
    def test_dependency_cycles_terminate(self):
        self.assertEqual(functions()['build_keys']({'v'},{'v','p'},{'v':{'p'},'p':{'v'}}),['p','v'])
    def test_missing_pixel_cannot_produce_cacheable_vertex(self):
        with tempfile.TemporaryDirectory() as d:
            f=functions(out=d,PAIRS={'v':{'p'}})['vs_pad']
            with self.assertRaises(ValueError):f('v','struct main0_out\n{\n};\nmain0_out out = {};')
    def test_dependency_supplies_hardware_default(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d)/'p_b.metal').write_text('float4 input [[user(locn5)]];')
            src='struct main0_out\n{\n    float4 position;\n};\nmain0_out out = {};'
            out,pad=functions(out=d,PAIRS={'v':{'p'}})['vs_pad']('v',src)
            self.assertEqual(pad,[5])
            self.assertIn('float4 dm_pad5 [[user(locn5)]];',out)
            self.assertIn('out.dm_pad5 = float4(0.0, 0.0, 0.0, 1.0);',out)
if __name__=='__main__':unittest.main()
