#!/usr/bin/env python3
# dm/tools/usage.py and dm/tools/impact_map.tsv (scripts/regress.py usage / impact): the map's globs name files of the repository, its patterns name usage kinds, the
# function scanner, the rule precedence and the manifests' format
import fnmatch, sys, tempfile, unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools'))
import usage

KINDS = {'api', 'key', 'present', 'shader', 'nvn', 'hle', 'svc', '*'}


class Usage(unittest.TestCase):
    def test_map_names_files_and_kinds(self):
        files = [str(p.relative_to(REPO)) for p in REPO.rglob('*') if p.is_file() and '.git' not in p.parts]
        for glob, frx, pat, why in usage.load_map():
            self.assertTrue(any(fnmatch.fnmatch(f, glob) for f in files), f'impact_map.tsv: {glob} matches no file')
            self.assertTrue(why, f'impact_map.tsv: {glob} gives no reason')
            if pat not in ('-', 'profile'): self.assertIn(pat.partition(':')[0], KINDS, f'impact_map.tsv: {glob}: unknown kind in {pat}')
            if frx is not None and glob.endswith('dmsh_build.py'):   # a function rule of the shader build names a function it has
                names = {n for n, _, _ in usage.functions(REPO / glob)}
                self.assertTrue(any(frx.search(n) for n in names), f'impact_map.tsv: {glob}:{frx.pattern} matches no function')

    def test_functions(self):
        src = 'static int a(void) {\n    return b(1);\n}\nNVN(nvnQueueFinish, void, NVNqueue *q) {\n    a();\n}\nHLE("_ZN2nn2fs4OpenEv", Result, h_open, void) {\n    return 0;\n}\n'
        self.assertEqual([n for n, _, _ in usage.functions('x.c', src)], ['a', 'nvnQueueFinish', 'h_open'])
        self.assertEqual([(n, a, b) for n, a, b in usage.functions('x.py', 'import os\ndef f():\n    pass\nclass C:\n    pass\n')], [('f', 2, 3), ('C', 4, 5)])

    def test_rule_precedence(self):
        rules = usage.load_map()
        rs, mapped = usage.rules_for('dm/gfx/tools/dmsh_build.py', {'fs_uint'}, rules)
        self.assertTrue(mapped); self.assertEqual({r[2] for r in rs}, {'shader:integer_outputs'})   # the function's rule, not the file's catch-all
        rs, _ = usage.rules_for('dm/gfx/tools/dmsh_build.py', {'some_new_function'}, rules)
        self.assertEqual({r[2] for r in rs}, {'shader:stage:*'})
        rs, mapped = usage.rules_for('dm/games/01007EF00011E000/README.md', {''}, rules)
        self.assertTrue(mapped); self.assertEqual(rs, [])   # documentation reaches no game

    def test_manifest_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'usage.tsv'
            usage.write_manifest(p, {('nvn', 'nvnQueueFinish'): 12, ('api', 'nvn'): 1, ('shader', 'image_atomic'): 3}, 'test')
            self.assertEqual(usage.read_manifest(p), {('nvn', 'nvnQueueFinish'): 12, ('api', 'nvn'): 1, ('shader', 'image_atomic'): 3})

    def test_committed_manifests(self):   # names and counts only
        for p in (REPO / 'dm/games').glob('*/usage.tsv'):
            for k, n in usage.read_manifest(p):
                self.assertIn(k, KINDS - {'*'}, p); self.assertNotIn('/', n if k != 'shader' else n.replace('/', ''), p)


if __name__ == '__main__':
    unittest.main()
