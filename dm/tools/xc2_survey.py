import sys, os, re, struct, zlib, collections, random
sys.path.insert(0, os.path.dirname(__file__)); import xc2_ard
C = bytes.fromhex('34127698')
def unpack(d):
    out = [d]
    for m in re.finditer(b'xbc1', d):
        o = m.start(); cs = struct.unpack_from('<I', d, o + 12)[0]
        try: out.append(zlib.decompress(d[o + 0x30:o + 0x30 + cs]))
        except Exception: pass
    return out
arh, ard = sys.argv[1:3]
files = [e for e in xc2_ard.read_arh(arh) if e[5]]
by = collections.defaultdict(list)
for e in files: by[e[5].rsplit('.', 1)[-1]].append(e)
random.seed(1)
with open(ard, 'rb') as f:
    for ext, es in sorted(by.items(), key=lambda x: -len(x[1])):
        s = random.sample(es, min(12, len(es))); hits = ctl = spch = 0
        for e in s:
            ds = unpack(xc2_ard.read_entry(f, e)); n = sum(x.count(C) for x in ds); ctl += n; hits += n > 0; spch += sum(x.count(b'HCPS') for x in ds)
        if hits: print(f'{ext}\t{len(es)} files\tsampled {len(s)}: {hits} with ctl, ctl {ctl}, HCPS {spch}')
