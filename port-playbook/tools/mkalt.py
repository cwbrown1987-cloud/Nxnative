import sys,os,hashlib
sys.path.insert(0,'dm/gfx/tools')
import shader_split as ss
from multiprocessing import Pool
R=sys.argv[1]; OUT=sys.argv[2]
def alt(ctl,code):
    n=ss.ctl_len(ctl); c=bytearray(ctl[:n])
    if n>=0x7d8: c[0x7d0:0x7d8]=bytes(8)
    return hashlib.sha256(bytes(c)+code).hexdigest()[:16]
def work(a):
    try:
        rel,u,_,_=ss.scan_file(a)
    except BaseException as e:
        sys.stderr.write('skip %s: %s\n'%(a[1],e)); return []
    if not isinstance(u,dict): return []
    return [(alt(v[2],v[3]),k,v[1]) for k,v in u.items()]
if __name__=='__main__':
    files=[]
    for r,_,fs in os.walk(R):
        for n in fs:
            p=os.path.join(r,n)
            if os.path.getsize(p)>8: files.append((p,os.path.relpath(p,R)))
    print(len(files),flush=True)
    m={}
    with Pool(8) as P:
        for res in P.imap_unordered(work,files,chunksize=8):
            for a,k,st in res: m[a]=(k,st)
    with open(OUT,'w') as f:
        f.write('# alt key (control bytes 0x7d0..0x7d7 zeroed) <TAB> map key <TAB> stage\n')
        for a,(k,st) in sorted(m.items()): f.write(f'{a}\t{k}\t{st}\n')
    print(len(m))
