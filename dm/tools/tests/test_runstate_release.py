"""In-process program switch (DM_PROGRAM_SWITCH=inproc, dm/host/progswitch.c): what the end of a run releases, checked against the sources.

The run's statics are reset by restoring the bytes of their sections (dm/host/dm_run.h), which zeroes a strong Objective-C reference without releasing what it holds.
So every strong static of the graphics layers must be released at the end of the run first:
- nvn_mtl.m (with nvn_rec.h and nvn_geometry.inc, which it includes): every file-scope strong static is set to nil in mtl_release_statics, and every strong static
  inside a function registers its slots with RUN_KEEP right after its declaration;
- hle_vk.m: every file-scope strong static is set to nil in dm_vk_end_run.
A static marked DM_PROCESS lives for the process and is left alone.
And every host source either places its statics in the run's sections (it includes dm.h or dm_run.h before them) or is one of the files that live for the process,
which opt out with #pragma clang section bss="" data="" (the front end, crash.c, memstat.m, hle_count.c, probe.c, progswitch.c).
No build needed: the sources are read as text."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[3]
GFX = REPO / 'dm/gfx'
OBJ = (r'(?:__strong\s+)?(?:id\b(?:\s*<[^>]*>)?|NS\w+(?:\s*<.*?>)?\s*\*|MTL\w+\s*\*|CA\w+\s*\*|Nv\w+\s*\*|DmRec\w+\s*\*|dispatch_queue_t)')


def strong_statics(text, indented):
    """(name, line) of the strong Objective-C statics declared at file scope (indented=False) or inside functions (True), DM_PROCESS ones left out"""
    out = []
    for ln, line in enumerate(text.split('\n'), 1):
        if bool(re.match(r'\s+static\s', line)) != indented or not re.match(r'\s*(?:DM_PROCESS\s+)?static\s', line) or 'DM_PROCESS' in line:
            continue
        code = line.split('//')[0]
        for stmt in code.split(';'):
            m = re.match(r'\s*static\s+(' + OBJ + r')\s*(.*)$', stmt)
            if not m or '(' in m.group(2) or '__unsafe_unretained' in stmt:
                continue
            for part in m.group(2).split(','):
                nm = re.match(r'\s*\*?\s*(\w+)', part)
                if nm:
                    out.append((nm.group(1), ln))
    return out


def body(text, head):
    i = text.index(head); j = text.index('{', i); d = 0
    for k in range(j, len(text)):
        d += {'{': 1, '}': -1}.get(text[k], 0)
        if not d:
            return text[j:k]
    raise AssertionError(f'no end for {head}')


class Release(unittest.TestCase):
    def test_metal_layer(self):
        mtl = (GFX / 'nvn/nvn_mtl.m').read_text()
        files = {p: (GFX / 'nvn' / p).read_text() for p in ('nvn_mtl.m', 'nvn_rec.h', 'nvn_geometry.inc')}
        rel = body(mtl, 'static void mtl_release_statics(void)')
        missing = [f'{p}:{ln} {n}' for p, t in files.items() for n, ln in strong_statics(t, False)
                   if not re.search(r'\b' + n + r' = nil;|NIL_ALL\(' + n + r'\)', rel)]
        self.assertEqual(missing, [], 'file-scope strong statics not released in mtl_release_statics')
        unkept = []
        for p, t in files.items():
            lines = t.split('\n')
            for n, ln in strong_statics(t, True):
                if not re.search(r'\b' + n + r'\b.*;\s*RUN_KEEP\(' + n + r'\)', lines[ln - 1]):
                    unkept.append(f'{p}:{ln} {n}')
        self.assertEqual(unkept, [], 'function statics without RUN_KEEP right after them')

    def test_vulkan_layer(self):
        vk = (GFX / 'vk/hle_vk.m').read_text()
        end = body(vk, 'void dm_vk_end_run(void)')
        missing = [f'hle_vk.m:{ln} {n}' for n, ln in strong_statics(vk, False) if not re.search(r'\b' + n + r' = nil;', end)]
        self.assertEqual(missing, [], 'strong statics of the Vulkan layer not released in dm_vk_end_run')
        self.assertEqual([f'hle_vk.m:{ln} {n}' for n, ln in strong_statics(vk, True)], [], 'a strong static inside a function of the Vulkan layer: release it at the end of the run')

    def test_placement(self):
        """Every host source of the Mac build and the iOS app: its statics in the run's sections, or a declared process file"""
        process = {'front_mac.m', 'web_apple.m', 'front_ios.m', 'DmGamepad.m', 'main.m', 'crash.c', 'memstat.m', 'hle_count.c', 'probe.c', 'progswitch.c'}
        no_state = {'haptics_apple.m', 'hle_haptics.c', 'nvn_deswizzle_gpu.m', 'nvn_tex.c', 'nvn_refl.m', 'nvn_deswizzle.c', 'nvn_fmt_mtl.c'}   # process-lifetime or no mutable state, never include dm.h
        srcs = [p for d in ('dm/host', 'dm/gfx', 'dm/gfx/nvn', 'dm/gfx/vk', 'dm/gfx/gl', 'dm/gfx/tex', 'dm/ios/Sources') for p in (REPO / d).glob('*.[cm]')]
        bad = []
        for p in srcs:
            t = p.read_text(errors='replace')
            opt_out = 'pragma clang section bss="" data=""' in t
            incl = re.search(r'#include "[./]*(?:host/)?(?:dm|hle|dm_run)\.h"', t)
            if p.name in process:
                if not opt_out and p.name != 'main.m':
                    bad.append(f'{p.name}: a process file without the opt-out pragma')
            elif p.name in no_state:
                continue
            elif opt_out:
                bad.append(f'{p.name}: opts out of the run sections but is not a declared process file')
            elif not incl:
                bad.append(f'{p.name}: includes neither dm.h, hle.h nor dm_run.h, so its statics are not reset between runs')
            elif re.search(r'^static\s[^(]*[;=]', t[:incl.start()], re.M):
                bad.append(f'{p.name}: statics before its first host include, outside the run sections')
        self.assertEqual(bad, [])


if __name__ == '__main__':
    unittest.main()
