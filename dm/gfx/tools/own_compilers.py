#!/usr/bin/env python3
# dmsh_build.py with this Mac's own compilers: the NSP script builds the iOS shader libraries through this file. dmsh_build.py stops when any tool differs from dmsh_chain.lock;
# here spirv-cross and the Metal compiler (macOS and iOS) may differ, with one note line naming them, while the translator (dmsh_xlate_bin) must still be the locked build.
# Neither the chain version nor any repository file changes: a player builds the shader libraries and the host on the same Mac, so the two agree whatever the compilers,
# and an Xcode or spirv-cross other than the maintainer's (a beta, a brew upgrade) no longer needs dmsh_chain.py --update-lock, which changes the chain version (one for every game).
# The lock stays the record of the compilers the libraries were tested with; on the maintainer's Mac dmsh_build.py keeps the strict check.
# The per-shader cache takes spirv-cross's version into its keys but the Metal compiler only through the lock, so after a Metal compiler change the shaders already in the cache
# keep the libraries the earlier compiler made and only new ones are compiled with this Mac's (the Metal compile cache, dmsh_mtlcache.py, is keyed by the compiler itself).
# Usage: own_compilers.py <dmsh_build.py arguments>   (the environment as for dmsh_build.py)
import os, re, sys, runpy
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE); import dmsh_chain
OWN = re.compile(r'(spirv-cross|metal_macosx|metal_iphoneos): lock (.*) / actual (?!missing$)(.*)')   # a missing compiler still stops the build
strict = dmsh_chain.check_tools

def check_tools():
    bad, own = [], []
    for b in strict(): (own if OWN.fullmatch(b) else bad).append(b)
    if own and not bad: print('note: built with this Mac\'s compilers, not the ones the shaders were tested with (dmsh_chain.lock): ' +
                  '; '.join(f'{m[1]} {m[3]} (tested: {m[2]})' for m in map(OWN.fullmatch, own)), flush=True)
    return bad

dmsh_chain.check_tools = check_tools   # dmsh_build.py imports the same module object and calls it through the module

# Tens of thousands of compiler runs: Popen takes posix_spawn only for a full path with close_fds off (Python's own fds are non-inheritable anyway, PEP 446);
# otherwise it forks the whole multithreaded process per run, which is most of the build's kernel time. The program found on PATH is the same one either way.
# `xcrun -sdk S tool ...` runs the tool by its full path with SDKROOT set instead, one process fewer per compile: the same tool and SDK, so the same bytes
# (400 of 400 iOS libraries identical to xcrun's), about 15% less compile time. The commands recorded in the libraries' json (MAC_RECORD, ios_metal.RECORD) stay as they are.
import shutil, subprocess, functools
_popen_init = subprocess.Popen.__init__
@functools.cache
def _xcrun(sdk, tool):   # (tool path, SDK path), or None when xcrun cannot say
    q = lambda *a: _popen_run(['/usr/bin/xcrun', '-sdk', sdk, *a])
    path, root = q('-f', tool), q('--show-sdk-path')
    return (path, root) if path and root else None
def _popen_run(cmd):
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True); out = p.communicate()[0]
    return out.strip() if p.returncode == 0 else ''
def _spawn_init(self, args, *a, **kw):
    if not a and isinstance(args, (list, tuple)) and args and 'executable' not in kw:
        args = [str(x) if isinstance(x, os.PathLike) else x for x in args]
        if len(args) > 3 and os.path.basename(args[0]) == 'xcrun' and args[1] == '-sdk' and not args[3].startswith('-') and (t := _xcrun(args[2], args[3])):
            args = [t[0], *args[4:]]; kw['env'] = {**(kw.get('env') or os.environ), 'SDKROOT': t[1]}
        elif not os.path.dirname(args[0]):
            args = [shutil.which(args[0], path=(kw.get('env') or os.environ).get('PATH')) or args[0], *args[1:]]
    kw.setdefault('close_fds', False)
    _popen_init(self, args, *a, **kw)
subprocess.Popen.__init__ = _spawn_init


sys.argv = [os.path.join(HERE, 'dmsh_build.py'), *sys.argv[1:]]
runpy.run_path(sys.argv[0], run_name='__main__')
