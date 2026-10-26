"""The pso pairs (the pipeline prebuild's own list) and the vertex output padding: the pair table is read as a set of pairs, and the shader build is handed the pso pairs (the
profile's own table, or the split's copy beside the shader package) so that every pair the prebuild builds links. No game files, keys, Xcode or GPU needed."""
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import types
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)
cspec = importlib.util.spec_from_file_location('dmsh_chain', REPO / 'dm/gfx/tools/dmsh_chain.py')
chain = importlib.util.module_from_spec(cspec); cspec.loader.exec_module(chain)


class ReadPairs(unittest.TestCase):
    def test_reads_the_table(self):
        with tempfile.TemporaryDirectory() as t:
            f = Path(t, 'pso_pairs.tsv')
            f.write_text('# header\nv1\tf1\n\nv2 f2\nv1\tf1\n')
            self.assertEqual(chain.read_pairs(f), {('v1', 'f1'), ('v2', 'f2')})   # the same pair twice is one pair

    def test_missing_file_is_no_pairs(self):
        self.assertEqual(chain.read_pairs(Path('/nowhere/pso_pairs.tsv')), set())
        self.assertEqual(chain.read_pairs(None), set())


class ShaderBuild(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.tmp)
        self.sh = self.tmp / 'shader'; (self.sh / 'pkg').mkdir(parents=True)
        self.profile = self.tmp / 'profile'; self.profile.mkdir()
        (self.profile / 'shader_map.tsv').write_text('')
        (self.profile / 'shader_pairs.tsv').write_text('')
        self.g = types.SimpleNamespace(table=lambda n: self.profile / n, dir=self.profile)
        self.ran = []; self.keys = []
        for cm in (mock.patch.object(nsp, 'PROG', mock.Mock()), mock.patch.object(nsp, 'say', lambda *a: None),
                   mock.patch.object(nsp, 'chain_tables', lambda *a, **k: True),
                   mock.patch.object(nsp, 'run', lambda cmd, log, env=None: self.ran.append(env)),
                   mock.patch.object(nsp, 'reused', lambda kf, key: self.keys.append(key) or None)):
            cm.__enter__(); self.addCleanup(cm.__exit__, None, None, None)
        self.env = {'WORK': str(self.tmp)}

    def build(self, pkg_key=None):
        libs = self.sh / 'ios' / f'b-{nsp.chain_of(REPO)}'; libs.mkdir(parents=True, exist_ok=True)
        (libs / 'x_b.metallib').write_text('')
        logs = self.tmp / 'logs'; logs.mkdir(exist_ok=True); (logs / 'dmsh_build.log').write_text('')
        nsp.build_shaders(sys.executable, REPO, self.sh, REPO / 'dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate', self.env, logs, self.g, pkg_key, False)
        return self.ran[-1]

    def test_the_splits_copy_when_the_profile_has_no_table(self):   # a profile made before the table existed: the split keeps it beside the package
        (self.sh / 'pso_pairs.tsv').write_text('v\tf\n')
        self.assertEqual(self.build()['DM_PSO_PAIRS'], str(self.sh / 'pso_pairs.tsv'))

    def test_the_profiles_own_table(self):
        (self.profile / 'pso_pairs.tsv').write_text('v\tf\n')
        self.assertEqual(self.build()['DM_PSO_PAIRS'], str(self.profile / 'pso_pairs.tsv'))

    def test_no_table_at_all(self):   # nothing to pad for: the shader build reads the profile's tables only
        self.assertNotIn('DM_PSO_PAIRS', self.build())

    def test_the_pairs_are_part_of_the_reuse_key(self):   # a changed pso pair list changes the padding, so the shaders are built again
        (self.sh / 'pso_pairs.tsv').write_text('v\tf\n')
        self.build('pkg')
        first = self.keys[-1]
        (self.sh / 'pso_pairs.tsv').write_text('v\tg\n')
        self.build('pkg')
        self.assertNotEqual(first, self.keys[-1])


if __name__ == '__main__':
    unittest.main()
