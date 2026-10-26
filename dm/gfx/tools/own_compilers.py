#!/usr/bin/env python3
# dmsh_build.py as a player's Mac runs it: the NSP script builds the shader libraries through this file. dmsh_build.py stops when any tool differs from dmsh_chain.lock;
# here spirv-cross may differ, with one note line naming it, while the translator (dmsh_xlate_bin) and the Metal compiler (macOS and iOS) must still be the locked ones.
# The Metal compiler is the one the shaders were tested with: shaders built with another one rendered wrong pictures (GitHub issue #242, Xcode 26 on macOS 26), so another one
# stops the build with a message naming the Xcode to install, unless DM_ALLOW_OTHER_METAL=1 (the NSP script's ALLOW_OTHER_METAL / --allow-other-metal), which builds with it and says so.
# Neither the chain version nor any repository file changes: a player builds the shader libraries and the host on the same Mac, so the two agree whatever the compilers,
# and a spirv-cross other than the maintainer's (a brew upgrade) needs no dmsh_chain.py --update-lock, which changes the chain version (one for every game).
# The lock stays the record of the compilers the libraries were tested with; on the maintainer's Mac dmsh_build.py keeps the strict check. This file is not part of the chain version.
# The per-shader cache takes spirv-cross's version into its keys but the Metal compiler only through the lock, so after a Metal compiler change (allowed) the shaders already in the cache
# keep the libraries the earlier compiler made and only new ones are compiled with this Mac's (the Metal compile cache, dmsh_mtlcache.py, is keyed by the compiler itself).
# Usage: own_compilers.py <dmsh_build.py arguments>   (the environment as for dmsh_build.py)
#        own_compilers.py --check-metal              only the Metal compiler check: exit 1 with the message when it would stop the build (the NSP script runs it before its shader steps)
import os, re, sys, runpy, subprocess
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE); import dmsh_chain
OWN = re.compile(r'(spirv-cross|metal_macosx|metal_iphoneos): lock (.*) / actual (?!missing$)(.*)')   # a missing compiler still stops the build
ALLOW = 'DM_ALLOW_OTHER_METAL'
XCODE = 'Xcode 27.1 (macOS 26.6 or later)'   # the Xcode whose Metal compiler dmsh_chain.lock records; README.md names it too
strict = dmsh_chain.check_tools

def allowed(): return os.environ.get(ALLOW) == '1'

def metal_version(sdk):   # as dmsh_chain.tools_now records it: the first line of metal --version, 'missing' without one
    r = subprocess.run(['xcrun', '-sdk', sdk, 'metal', '--version'], capture_output=True, text=True)
    return (r.stdout.splitlines() or ['missing'])[0]

def other_metal_message(metal):
    """The stop message for the Metal compilers that differ from the lock: [(lock key, tested, actual)]"""
    return ('[RED] this Mac\'s Metal compiler is not the one the shaders were tested with (dm/gfx/tools/dmsh_chain.lock): ' +
            '; '.join(f'{k} {now} (tested: {want})' for k, want, now in metal) +
            f'. Shaders built with another Metal compiler can render wrong pictures (GitHub issue #242). Install {XCODE} and its Metal toolchain '
            f'(xcodebuild -downloadComponent MetalToolchain), or set {ALLOW}=1 (the NSP script\'s --allow-other-metal) to build with this one anyway')

def other_metal():
    """The Metal compilers (macOS, iOS) that differ from the lock and are present: [(lock key, tested, actual)]; a missing one is dmsh_build.py's to report"""
    with open(dmsh_chain.LOCK) as f: want = dict(l.rstrip('\n').split('\t', 1) for l in f if '\t' in l and not l.startswith('#'))
    out = []
    for sdk in ('macosx', 'iphoneos'):
        now = metal_version(sdk)
        if now != 'missing' and now != want.get('metal_' + sdk): out.append(('metal_' + sdk, want.get('metal_' + sdk), now))
    return out

def check_metal():   # --check-metal: the stop message, '' when the build may go on
    metal = other_metal()
    return other_metal_message(metal) if metal and not allowed() else ''

def check_tools():
    bad, own = [], []
    for b in strict():
        m = OWN.fullmatch(b)
        if m: own.append((m[1], m[2], m[3]))   # (lock key, tested, actual)
        else: bad.append(b)
    if bad: return bad
    metal = [o for o in own if o[0] != 'spirv-cross']
    if metal and not allowed(): sys.exit(other_metal_message(metal))
    if own: print('note: built with this Mac\'s compilers, not the ones the shaders were tested with (dmsh_chain.lock): ' +
                  '; '.join(f'{k} {now} (tested: {want})' for k, want, now in own) + (f' ({ALLOW}=1)' if metal else ''), flush=True)
    return []

if __name__ == '__main__':
    if sys.argv[1:] == ['--check-metal']:
        msg = check_metal()
        if msg: print(msg)
        sys.exit(1 if msg else 0)
    dmsh_chain.check_tools = check_tools   # dmsh_build.py imports the same module object and calls it through the module
    sys.argv = [os.path.join(HERE, 'dmsh_build.py'), *sys.argv[1:]]
    runpy.run_path(sys.argv[0], run_name='__main__')
