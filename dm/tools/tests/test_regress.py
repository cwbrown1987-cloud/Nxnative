#!/usr/bin/env python3
# scripts/regress.py: the parts that need no game, GPU or git revision: the MSL interface reader (GitHub issue #283), the [RED] normalization, the routes, and the comparisons
import importlib.util, tempfile, unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('regress', REPO / 'scripts/regress.py'); regress = importlib.util.module_from_spec(spec); spec.loader.exec_module(regress)

VS = '''struct main0_out
{
    float4 m_51 [[user(locn0)]];
    float4 m_55 [[user(locn2), flat]];
    float4 gl_Position [[position, invariant]];
};

struct main0_in
{
    float4 a0 [[attribute(0)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
}

vertex main0_out main0_z(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
}
'''
PS = '''struct main0_out
{
    float4 c0 [[color(0)]];
};

struct main0_in
{
    float4 m_1 [[user(locn0)]];
    float4 m_2 [[user(locn1)]];
    int4 m_3 [[user(locn2), flat]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], float4 gl_FragCoord [[position]])
{
}
'''


class Regress(unittest.TestCase):
    def test_interface(self):
        vo, fi = regress.msl_io(VS, 'main0_z', 'vs'), regress.msl_io(PS, 'main0', 'ps')
        self.assertEqual(vo, {'locn0': 'float4', 'locn2': 'float4'})
        self.assertEqual(fi, {'locn0': 'float4', 'locn1': 'float4', 'locn2': 'int4'})
        self.assertIsNone(regress.msl_io(VS, 'main1', 'vs'))
        self.assertEqual(regress.msl_io('fragment main0_out main0(constant X& x [[buffer(0)]])\n{\n}\n', 'main0', 'ps'), {})   # no stage inputs

    def test_red_normalized(self):
        a = regress.normalize_red('[dm] [RED] shader 0a91af5bef8578e2: 12 bindings at 0x1f00 in /Volumes/NX/games/x [y]/b')
        b = regress.normalize_red('[dm] [RED] shader 1b91af5bef8578e3: 7 bindings at 0x2000 in /tmp/z')
        self.assertEqual(a, b)

    def test_routes(self):   # every profile's smoke.tsv reads
        for f in (REPO / 'dm/games').glob('*/smoke.tsv'):
            r = regress.read_route(f)
            self.assertTrue(r['secs'] > 0 and r['quick'] > 0 and r['keys'], f)
            if r['reach']: self.assertTrue(r['reach'][1] <= r['secs'], f)

    def test_chain_diff(self):
        b = {'shaders': {'a': {'st': 'ok', 'msl': '1'}, 'b': {'st': 'ok', 'msl': '2'}, 'c': {'st': 'metal failed'}, 'd': {'st': 'ok', 'msl': '4'}},
             'interface': {'bad': [{'vs': 'v', 'entry': 'main0', 'ps': 'p', 'missing': ['locn1'], 'type': []}]}}
        c = {'shaders': {'a': {'st': 'ok', 'msl': '1'}, 'b': {'st': 'metal failed', 'err': 'x'}, 'c': {'st': 'ok', 'msl': '3'}, 'd': {'st': 'ok', 'msl': '5'}},
             'interface': {'bad': [{'vs': 'v', 'entry': 'main0', 'ps': 'p', 'missing': ['locn1'], 'type': []}, {'vs': 'w', 'entry': 'main0', 'ps': 'p', 'missing': ['locn6'], 'type': []}]}}
        d = regress.chain_diff(b, c)
        self.assertEqual([x['key'] for x in d['newly_failing']], ['b']); self.assertEqual(d['newly_passing'], ['c'])
        self.assertEqual(d['changed']['msl'], 1); self.assertEqual(d['changed']['keys'], ['d'])
        self.assertEqual([x['vs'] for x in d['interface']['new']], ['w']); self.assertEqual(len(d['interface']['known']), 1)

    def test_smoke_diff(self):
        route = {'reach': (100, 30.0)}
        shot = {'dhash': '0f0f0f0f0f0f0f0f', 'rgb16': '10' * 768}
        base = [{'exit': None, 'max_frame': 500, 'reached': True, 'fps': 60, 'frame_p99': 17, 'peak_footprint_mb': 4000, 'prepare_s': 1.0, 'red': {'a #': 2}, 'shots': {'45': shot}}]
        same = [dict(base[0])]
        lv, known, d = regress.smoke_diff(base, same, route)
        self.assertFalse(lv['NEW-FAIL'] or lv['REGRESSION'] or lv['CHANGED'], lv)
        bad = [dict(base[0], exit=-11, crash={'signal': 'SIGSEGV'}, red={'a #': 1, 'b #': 3}, fps=40, shots={'45': {'dhash': 'f0f0f0f0f0f0f0f0', 'rgb16': '80' * 768}})]
        lv, known, d = regress.smoke_diff(base, bad, route)
        self.assertTrue(any('crash' in x for x in lv['NEW-FAIL']), lv)
        self.assertTrue(any('RED' in x for x in lv['REGRESSION']) and any('fps' in x for x in lv['REGRESSION']) and any('screenshot' in x for x in lv['REGRESSION']), lv)
        self.assertEqual(d['new_red'], [{'text': 'b #', 'count': 3}])
        lv, known, d = regress.smoke_diff(bad, bad, route)   # a failure the baseline has too is known, not new
        self.assertFalse(lv['NEW-FAIL']); self.assertTrue(known)
        quit0 = [dict(base[0], exit=0)]   # the game ended by itself before the route did: a failure even with exit status 0
        self.assertTrue(any('exited before the end' in x for x in regress.smoke_diff(base, quit0, route)[0]['NEW-FAIL']))

    def test_status_order(self):
        self.assertEqual(regress.worst('PASS', 'CHANGED', 'REGRESSION'), 'REGRESSION'); self.assertEqual(regress.worst('NEW-FAIL', 'ERROR'), 'ERROR')


if __name__ == '__main__':
    unittest.main()
