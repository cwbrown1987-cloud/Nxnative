#!/usr/bin/env python3
# Adds shaders the game produces at run time (found in no game file) to the package + mapping table, from the host's DM_NVN_SHDUMP output.
# Usage: shader_adddump.py <dump dir (<key>.ctl + <key>.code)> <pkg dir> <shader_map.tsv>   (run after shader_split.py, before dmsh_build.py; idempotent)
# The key is the one the host computes at run time (the control section as the game left it), so the host finds the entry without the alt-key lookup.
import sys, os, struct, glob
dump, pkg, mp = sys.argv[1:4]
have = {l.split('\t')[3] for l in open(mp) if l[0] != '#' and l.count('\t') > 3}
STAGE = {1: ('vs', 'vertex'), 21: ('ps', 'pixel')}   # SPH type (code area +0x30 word 0 bits 10..14)
recs, rows = {}, []
for f in sorted(glob.glob(os.path.join(dump, '*.ctl'))):
    key = os.path.basename(f)[:-4]
    if key in have: continue
    ctl = open(f, 'rb').read(); code = open(f[:-4] + '.code', 'rb').read()
    t = (struct.unpack_from('<I', code, 0x30)[0] >> 10) & 0x1f
    if t not in STAGE: print(f'skip {key}: SPH type {t}'); continue
    st, sname = STAGE[t]; name = f'{st}_rtdump.bin'
    rec = bytearray(b'BTCDBTCD' + bytes(0x30)); struct.pack_into('<2I', rec, 0x28, len(ctl), len(code)); rec += code + ctl
    recs.setdefault(name, []).append(bytes(rec)); rows.append((name, len(recs[name]) - 1, sname, key))
for name, rr in recs.items():
    with open(os.path.join(pkg, name), 'wb') as f: f.write(b''.join(rr))
with open(mp, 'a') as f:
    for name, i, sname, key in rows: f.write(f'{name}\t{i}\t{sname}\t{key}\truntime dump (shader_adddump.py)\n')
print(f'added {len(rows)} run-time shaders')
