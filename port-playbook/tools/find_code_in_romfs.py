import sys,os,glob,struct
sys.path.insert(0,'/Volumes/RAGHAV SSD/nintendo/nxnative/dm/gfx/tools')
B=sys.argv[1]
keys=[]
for l in open('bad.txt'): keys.append(l.strip())
pat={}
for k in keys:
    code=open(f'shdump/{k}.code','rb').read(); pat[k]=code[0x100:0x140]   # skip header-ish bytes
def lz4(src,n):
    o=bytearray();i=0
    while i<len(src):
        t=src[i];i+=1;l=t>>4
        if l==15:
            while True:
                b=src[i];i+=1;l+=b
                if b!=255:break
        o+=src[i:i+l];i+=l
        if i>=len(src):break
        off=src[i]|src[i+1]<<8;i+=2;m=t&15
        if m==15:
            while True:
                b=src[i];i+=1;m+=b
                if b!=255:break
        m+=4
        for _ in range(m):o.append(o[-off])
    return bytes(o)
found={}
def chk(d,lab):
    for k,p in pat.items():
        if k not in found and p in d: found[k]=lab
files=glob.glob(B+'/extract/v131072/RomFS/**/*',recursive=True)+glob.glob(B+'/extract/v131072/ExeFS/*')+glob.glob(B+'/patched_v131072/*')
for f in files:
    if not os.path.isfile(f):continue
    d=open(f,'rb').read(); chk(d,f)
    if d[:8]==b'GFLXPACK':
        n=struct.unpack_from('<I',d,0x10)[0];fo=struct.unpack_from('<Q',d,0x18)[0]
        for i in range(n):
            lv,c,sz,ps,_,off=struct.unpack_from('<HHIIIQ',d,fo+i*0x18)
            try:
                m=d[off:off+ps]; 
                if c==2:m=lz4(m,sz)
                chk(m,f+'#%d'%i)
            except Exception as e:pass
print(len(found),len(pat));
for k,v in found.items():print(k,v)
