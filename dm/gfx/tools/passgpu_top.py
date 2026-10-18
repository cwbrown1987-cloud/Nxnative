# Per-pass GPU (DM_NVN_PASSGPU, Metal 4 counter heap; for the columns see the comment in nvn_mtl.m): per frame GPU busy (the timeline increment of each pass),
# idle between passes inside a segment and at segment changes, idle grouped by the transition (R render / C compute / B copy), and the costliest pass classes.
# Usage: passgpu_top.py <passgpu.tsv> [first frame, default 300] [top N, default 10] [per-frame DM_NVN_TSV file, for @gpu_ms]
import sys, collections, statistics as S
X = sys.argv[1]; F0 = int(sys.argv[2]) if len(sys.argv) > 2 else 300; N = int(sys.argv[3]) if len(sys.argv) > 3 else 10
rows = [r for r in (l.rstrip('\n').split('\t') for l in open(X)) if len(r) == 15 and r[0].isdigit()]   # the last line may be cut off at exit
busy, gin, gseg = collections.Counter(), collections.Counter(), collections.Counter()
cls, tr = collections.defaultdict(float), collections.defaultdict(list)
prev_end, prev = 0, None
for r in rows:
    f, kind, a, b, seg = int(r[0]), r[2], int(r[3]), int(r[4]), int(r[6])
    inc = max(0, b - max(a, prev_end)) / 1e6
    gap = (a - prev_end) / 1e6 if prev_end else 0
    if f > F0:
        busy[f] += inc
        if gap > 0:
            if prev and int(prev[6]) == seg: gin[f] += gap; tr[(prev[2], kind)].append(gap)
            else: gseg[f] += gap
        cls[(kind, r[7] + 'x' + r[8], r[9], r[10], r[13])] += inc
    prev_end = max(prev_end, b); prev = r
fr = sorted(busy); n = len(fr)
if not n: sys.exit('没有 %d 帧之后的行' % F0)
q = lambda v: '%.2f / %.2f' % (S.median(v), sorted(v)[int(len(v) * .95)])
g = {}
if len(sys.argv) > 4:
    for l in open(sys.argv[4]):
        p = l.rstrip('\n').split('\t')
        if len(p) == 3 and p[0].isdigit() and p[1] == '@gpu_ms': g[int(p[0])] = float(p[2])
c = [f for f in fr if f in g]
print('帧数 %d；每帧 GPU 忙 p50 / p95 %s ms，同一段内通道间空闲 %s ms，换段处空闲 %s ms%s' % (n, q([busy[f] for f in fr]), q([gin[f] for f in fr]), q([gseg[f] for f in fr]),
      '；同帧 @gpu_ms %s ms' % q([g[f] for f in c]) if c else ''))
print('同一段内的空闲按前后通道种类（每帧次数，中位 µs，每帧合计 ms）：')
for k, v in sorted(tr.items(), key=lambda kv: -sum(kv[1]))[:6]:
    print('  %s→%s：%.1f 次，中位 %.1f µs，合计 %.2f ms' % (k[0], k[1], len(v) / n, S.median(v) * 1e3, sum(v) / n))
tot = sum(cls.values()) / n
print('最费的通道类（种类 尺寸 颜色格式 深度格式 片元着色器 / 拷贝来源：每帧 ms，占忙时比例）：')
for k, v in sorted(cls.items(), key=lambda kv: -kv[1])[:N]:
    print('  %s %s fmt%s d%s %s：%.3f ms，%4.1f%%' % (k[0], k[1], k[2], k[3], k[4], v / n, 100 * v / n / tot))
