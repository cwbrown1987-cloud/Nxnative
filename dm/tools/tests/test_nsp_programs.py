"""NSP script, multi-program applications (scripts/build_ipa_from_nsp.py program_list / main): which programs are packed together (PROGRAMS / --programs, else 0 and every program
whose title ID, base + index, has a game profile), and on the Mac the programs.tsv the host reads (DM_PROGRAMS, hle_oe.c) and the one run command over them.
No game files, keys or Xcode needed (temporary files only in a temporary folder)."""
import importlib.util
from pathlib import Path
import os
import shutil
import sys
import tempfile
import types
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / 'scripts/build_ipa_from_nsp.py'
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', SCRIPT)
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)
APP = 0x010049900F546000


class Programs(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.tmp)
        fake = types.ModuleType('game'); fake.by_title = lambda t: object() if t in (APP, APP + 2) else None   # profiles of programs 0 and 2 (3D All-Stars' launcher and Sunshine)
        for cm in (mock.patch.dict(sys.modules, {'game': fake}), mock.patch.object(nsp, 'scan_nsps', lambda d: (APP, {})), mock.patch.object(nsp, 'PROGRAM', 0),
                   mock.patch.object(nsp, 'PROGRAMS', ''), mock.patch.object(nsp, 'PROG', mock.Mock()), mock.patch.object(nsp, 'say', lambda m: None)):
            cm.__enter__(); self.addCleanup(cm.__exit__, None, None, None)

    def plist(self, programs=None):
        return nsp.program_list(types.SimpleNamespace(programs=programs), self.tmp, REPO)

    def test_profiles(self):   # 0 and every program with a profile; Galaxy (3) and Super Mario 64 (1) have none here
        self.assertEqual(self.plist(), [0, 2])

    def test_option(self):
        self.assertEqual(self.plist('2'), [0, 2])
        self.assertEqual(self.plist('0, 1,2'), [0, 1, 2])
        self.assertIsNone(self.plist('0'))   # one program: packed as before
        for bad in ('x', '0,16'):
            with self.assertRaises(nsp.BuildError): self.plist(bad)

    def test_one_program_by_index(self):   # PROGRAM / --program N packs that program alone
        with mock.patch.object(nsp, 'PROGRAM', 2): self.assertIsNone(self.plist())

    def test_mac_run_over_programs(self):   # each program packed from its own profile, then programs.tsv and one command that starts program 0 with DM_PROGRAMS
        seen = []
        def pack_one(args, multi=False):
            seen.append((nsp.PROGRAM, multi, os.environ.get('DM_GAMES_DIR')))
            os.environ['DM_GAMES_DIR'] = f'/provisional/{nsp.PROGRAM}'   # what a provisional profile's run sets: must not reach the next program
            b = self.tmp / f'{APP + nsp.PROGRAM:016X}_build'; (b / 'run').mkdir(parents=True)
            env = {'DM_ROOT': b, 'DM_ROMFS': b / 'extract/v0/RomFS', 'DM_LANG': 'en-US', 'DM_WINDOW': 1, 'DM_AUDIO': 1}
            if nsp.PROGRAM == 0: env['DM_NVN_SHMAP'] = REPO / 'dm/games/010049900F546000/shader_map.tsv'
            return {'cmd': f'cd {b / "run"} && DM_ROOT={b} {b / "tools/dmhost"} {b / "patched_v0"}', 'env': env, 'host': b / 'tools/dmhost', 'arg': b / 'patched_v0', 'cwd': b / 'run'}
        out = []
        args = nsp.parse_args([str(self.tmp), '--platform', 'mac'])
        with mock.patch.object(nsp, 'pack_one', pack_one), mock.patch.dict(os.environ, {}, clear=False), mock.patch.object(nsp.PROG, 'say', out.append):
            os.environ.pop('DM_GAMES_DIR', None)
            runs = nsp.main(args)
        self.assertEqual([s[:2] for s in seen], [(0, True), (2, True)])
        self.assertEqual([s[2] for s in seen], [None, None])
        tsv = self.tmp / f'{APP:016X}_build/programs.tsv'
        rows = [l.split('\t') for l in tsv.read_text().splitlines() if not l.startswith('#')]
        self.assertEqual([r[0] for r in rows], ['0', '2'])
        b2 = self.tmp / f'{APP + 2:016X}_build'
        self.assertEqual(rows[1][1:4], [f'exe={b2 / "tools/dmhost"}', f'arg={b2 / "patched_v0"}', f'cwd={b2 / "run"}'])
        self.assertIn('DM_LANG=en-US', rows[1]); self.assertIn(f'DM_ROOT={b2}', rows[1])
        self.assertFalse(any(f.startswith(('DM_WINDOW=', 'DM_AUDIO=')) for r in rows for f in r))   # the run command's own switches, inherited
        self.assertTrue(any(f.startswith('DM_NVN_SHMAP=') for f in rows[0])); self.assertFalse(any(f.startswith('DM_NVN_SHMAP=') for f in rows[1]))
        self.assertEqual(len(out), 1); self.assertIn(f'&& DM_PROGRAMS={tsv} DM_ROOT=', out[0]); self.assertTrue(out[0].startswith(f'cd {self.tmp / f"{APP:016X}_build/run"} && '))
        self.assertEqual(sorted(runs), [0, 2])

    def test_ios_one_ipa(self):   # the iPhone: every program's parts, then one build_ipa.sh run with PROGRAMS_TSV over program 0's app
        def pack_one(args, multi=False):
            b = self.tmp / f'{APP + nsp.PROGRAM:016X}_build'; (b / 'logs').mkdir(parents=True)
            return {'ipa_env': {'GAME': f'{APP + nsp.PROGRAM:016X}'}, 'out_ipa': self.tmp / f'p{nsp.PROGRAM}.ipa', 'work': b, 'ex': b / 'extract', 'keep': True, 'reg': None, 'g': None,
                    'pkg_ver': 'v0', 'derived': False, 'provisional': False, 'row': (nsp.PROGRAM, f'{APP + nsp.PROGRAM:016X}', b / 'patched_v0', b / 'extract/v0/RomFS', b / 'shader/ios', 'vulkan' if nsp.PROGRAM else 'nvn')}
        ran = []
        def run(cmd, log, env=None, cwd=None, on_line=None):
            ran.append(env); Path(cmd[-1]).write_bytes(b'ipa')
        args = nsp.parse_args([str(self.tmp), '--platform', 'ios'])
        with mock.patch.object(nsp, 'pack_one', pack_one), mock.patch.object(nsp, 'run', run), mock.patch.object(nsp, 'free_gb', lambda p: 100), \
             mock.patch.object(nsp, 'report_profile_status', lambda *a: None), mock.patch.object(nsp, 'IpaWatch', mock.Mock()):
            nsp.main(args)
        self.assertEqual(len(ran), 1); self.assertEqual(ran[0]['GAME'], f'{APP:016X}')
        rows = [l.split('\t') for l in Path(ran[0]['PROGRAMS_TSV']).read_text().splitlines() if not l.startswith('#')]
        self.assertEqual([(r[0], r[1], r[5]) for r in rows], [('0', f'{APP:016X}', 'nvn'), ('2', f'{APP + 2:016X}', 'vulkan')])
        self.assertTrue((self.tmp / 'p0.ipa').is_file())   # program 0's IPA name


class HeaderMulti(unittest.TestCase):   # game.py header-multi: the host over a table of the programs' profiles, DM_PROGRAM picking the entry (main.c dm_game_cur)
    def test_values_follow_the_program(self):
        tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, tmp)
        import subprocess
        subprocess.run([sys.executable, REPO / 'dm/games/game.py', 'header-multi', tmp / 'game_profile.h', '0=010049900F546000', '2=010049900F546002'], check=True)
        (tmp / 't.c').write_text('#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n#include "game_profile.h"\n'
            'const dm_game_t *dm_game_cur(void) { const char *e = getenv("DM_PROGRAM"); for (size_t i = 0; i < sizeof dm_games / sizeof *dm_games; i++) if (dm_games[i].program == (e ? atoi(e) : 0)) return &dm_games[i]; return &dm_games[0]; }\n'
            'int main(void) { const struct { const char *b, *v; } k[] = {DM_GAME_DISPLAY_VERSIONS}; int nv = 0; for (unsigned j = 0; j < sizeof k / sizeof *k; j++) nv += k[j].b != NULL;\n'
            '  printf("%s %llx %d %s %d %d\\n", DM_GAME_ID, (unsigned long long)DM_GAME_MEM_RESERVE, DM_GAME_RENDER_COND, DM_GAME_MODULES_ARR[1], DM_GAME_NMOD, nv); return 0; }\n')
        subprocess.run(['clang', '-Wall', '-Werror', '-o', tmp / 't', tmp / 't.c'], check=True)
        out = lambda p: subprocess.run([tmp / 't'], env=dict(os.environ, DM_PROGRAM=p), capture_output=True, text=True, check=True).stdout.split()
        self.assertEqual(out('0'), ['010049900F546000', '100000000', '1', 'subsdk0', '3', '1'])
        self.assertEqual(out('2'), ['010049900F546002', '180000000', '0', 'subsdk0', '3', '1'])


if __name__ == '__main__':
    unittest.main()
