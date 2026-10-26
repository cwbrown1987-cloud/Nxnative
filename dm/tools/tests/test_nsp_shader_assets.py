"""Optional shader assets get local tables without changing registered builds or source profiles."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    out = importlib.util.module_from_spec(spec); spec.loader.exec_module(out)
    return out
nsp = module('nsp', REPO / 'scripts/build_ipa_from_nsp.py')
game = module('game_assets', REPO / 'dm/games/game.py')

class ShaderAssets(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.src = self.root / 'registered/0100317013770000'
        self.src.mkdir(parents=True)
        self.profile = 'title_id\t0100317013770000\nprogram_id\t0100317013770000\nbuild\tv1\t1.0\tmain=1234\npackage\tv1\nshader_versions\tv1\nmem_alias\t0x400000000\n'
        (self.src / 'game.tsv').write_text(self.profile)
        self.generated = ('shader_map.tsv', 'shader_map.tsv.conflicts.tsv', 'shader_facts.tsv', 'shader_pairs.tsv', 'pso_pairs.tsv', 'c1_full.tsv', 'cb_extent.tsv')
        self.manual = ('shader_facts_manual.tsv', 'patches.py', 'pso_manifest.tsv', 'bf_want.tsv')
        for name in self.generated + self.manual: (self.src / name).write_text('# ' + name + '\n')
        self.g = game.Game(self.src)

    def test_preserves_registered_builds_settings_and_manual_rules(self):
        dst = self.root / 'local' / self.g.id
        g = nsp.shader_asset_profile(self.g, dst)
        self.assertEqual(g.builds(), self.g.builds())
        self.assertEqual((dst / 'game.tsv').read_text(), self.profile)
        for name in self.manual: self.assertEqual((dst / name).read_bytes(), (self.src / name).read_bytes())
        for name in self.generated: self.assertFalse((dst / name).exists(), name)
        for name in self.generated: self.assertTrue((self.src / name).exists(), name)

    def test_refresh_removes_stale_generated_tables(self):
        dst = self.root / 'local' / self.g.id
        nsp.shader_asset_profile(self.g, dst)
        (dst / 'shader_map.tsv').write_text('stale optional shaders')
        nsp.shader_asset_profile(self.g, dst)
        self.assertFalse((dst / 'shader_map.tsv').exists())
        self.assertEqual((self.src / 'game.tsv').read_text(), self.profile)

    def test_refuses_overwriting_source_profile(self):
        with self.assertRaises(nsp.BuildError): nsp.shader_asset_profile(self.g, self.src)
        self.assertEqual((self.src / 'game.tsv').read_text(), self.profile)
