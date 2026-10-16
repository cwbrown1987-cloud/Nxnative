#!/usr/bin/env python3
# 翻译查询的作答表（游戏档案目录 dm/games/<名>/shader_facts.tsv）：每个 Switch 着色器键一行，记翻译器问得到、但 Switch 机器码里读不出的那几项事实——
# 贴图 / 图像的维度类型、图像格式、顶点属性与片元输出的分量类型、计算着色器的线程组大小与共享内存字节数。
# 这些事实取自与它一一配对的 PC 版着色器的反射（NVN 槽号 = D3D 寄存器号，见 dm/gfx/README.md）。表随仓库，出着色器库只读这张表，
# 不需要 PC 版游戏文件；表里没有的键，翻译查询按缺省作答（出包汇总里单列）。
# 用法：dmsh_facts.py --freeze   从 PC 反射重出整张表（维护者用；要 PCCACHE 反射目录、PC DXBC 目录与 vkd3d-compiler）
#       dmsh_facts.py --check    重算一遍与仓内的表逐键比对，不一致报红退出 1（同上，要 PC 侧输入）
#       dmsh_facts.py            打印表的行数与各项事实的覆盖数
#       dmsh_facts.py --fout-merge <文件>   把宿主运行时记下的整数片元输出（DM_NVN_FOUT_WANT）并进游戏档案的 shader_fout.tsv；同一键同一颜色前后类型不一报红退出 1
#         没有 PC 版的游戏（王国之泪）片元输出类型只有这个来源：load() 把它并进事实（覆盖同键同色的值），出包只重出表里变了的键
# 行格式：键 <TAB> JSON（键按字典序、紧凑写法；同样的输入逐字节同样的表）
# Answer table for translation queries (dm/games/<id>/shader_facts.tsv in the game profile folder): one row per Switch shader key, recording the few facts the translator asks for but that cannot be read from the Switch machine code -
# dimension type of textures / images, image format, component types of vertex attributes and fragment outputs, thread group size and shared memory bytes of compute shaders.
# These facts come from the reflection of the PC shader paired one-to-one with it (NVN slot number = D3D register number, see dm/gfx/README.md). The table ships with the repo; building the shader library reads only this table
# and needs no PC game files; for keys not in the table, translation queries are answered with defaults (listed separately in the build summary).
# Usage: dmsh_facts.py --freeze   regenerate the whole table from PC reflection (for maintainers; needs the PCCACHE reflection dir, the PC DXBC dir and vkd3d-compiler)
#       dmsh_facts.py --check    recompute and compare key by key against the in-repo table; on mismatch report a failure and exit 1 (as above, needs the PC-side inputs)
#       dmsh_facts.py            print the table's row count and the coverage count of each fact
#       dmsh_facts.py --fout-merge <file>   fold the integer fragment outputs the host recorded at runtime (DM_NVN_FOUT_WANT) into the profile's shader_fout.tsv; the same key and color seen with two types is reported red with exit 1
#         For games without a PC version (TotK) this is the only source of fragment output types: load() merges it into the facts (overriding the same key and color), and the build rebuilds only the keys whose rows changed
# Row format: key <TAB> JSON (keys in lexicographic order, compact form; the same input gives a byte-identical table)
import json, os, re, subprocess, sys
DM_ROOT = os.environ.get('DM_ROOT') or os.path.expanduser('~/dm-work')   # 工作区根目录（游戏文件、产物、运行现场都在它下面） | Workspace root (game files, build outputs and run artifacts are all under it)
HERE = os.path.dirname(os.path.abspath(__file__)); HOME = os.path.expanduser('~')
sys.path.insert(0, os.path.join(HERE, '../../games')); import game as _game   # 表在当前游戏档案目录（DM_GAME） | the tables are in the current game profile folder (DM_GAME)
TABLE = str(_game.load().table('shader_facts.tsv')); MAP = str(_game.load().table('shader_map.tsv')); FOUT = str(_game.load().table('shader_fout.tsv'))
TT = {'texture1d': '1d', 'texture1darray': '1darray', 'texture2d': '2d', 'texture2darray': '2darray', 'texture2dms': '2dms',
      'texture2dmsarray': '2dmsarray', 'texture3d': '3d', 'texturecube': 'cube', 'texturecubearray': 'cubearray', 'buffer_typed': 'buffer'}
CT = {'float': 'float', 'int': 'sint', 'uint': 'uint'}

def read_tsv(path):
    if not os.path.exists(path): return {}
    return {k: json.loads(v) for k, v in (l.rstrip('\n').split('\t', 1) for l in open(path) if l.strip() and not l.startswith('#'))}

def load(observed=True):
    """键 → 事实字典；表不存在返回空字典。observed：并入运行时观察到的片元输出类型（shader_fout.tsv），只有这个来源的键仍记 pc_missing
    | key → fact dict; returns an empty dict if the table does not exist. observed: merge in the runtime-observed fragment output types (shader_fout.tsv); keys known only from there still carry pc_missing"""
    t = read_tsv(TABLE)
    if observed:
        for k, v in read_tsv(FOUT).items():
            f = t.setdefault(k, {'pc_missing': True}); f['fout'] = {**f.get('fout', {}), **v}
    return t

def row(key, facts): return key + '\t' + json.dumps(facts, sort_keys=True, separators=(',', ':'), ensure_ascii=False) + '\n'

def from_pc(pj, stage, dxbc_asm):
    """PC 反射 json（pj）+ 计算着色器的 DXBC 反汇编文本（没有给 None）→ 事实字典 | PC reflection json (pj) + DXBC disassembly text of the compute shader (None if absent) → fact dict"""
    f = {'tex': {}, 'img': {}, 'attr': {}, 'fout': {}}
    for b in pj['bindings']:
        if b['kind'] == 't' and b['type'] in TT: f['tex'][str(b['reg'])] = TT[b['type']]
        if b['kind'] == 'u' and b['type'] in TT:
            f['img'][str(b['reg'])] = {'type': TT[b['type']], 'fmt': 'R32Uint' if 'uint' in (b.get('msl_type') or '') else 'R16G16B16A16Float'}
    for v in pj.get('vertex_inputs') or []: f['attr'][str(v.get('location', v.get('index')))] = CT.get(v.get('component_type'), 'float')
    for o in pj.get('fragment_outputs') or []: f['fout'][str(o.get('index', 0))] = CT.get(o.get('component_type'), 'float')
    if pj.get('threadgroup_size'): f['local'] = pj['threadgroup_size']
    if stage == 'cs':   # 共享内存：PC DXBC 的 groupshared 声明求和（翻译器缺省 48 KB，超 Metal 上限 32 KB） | shared memory: sum of the groupshared declarations in the PC DXBC (the translator default is 48 KB, over Metal's 32 KB limit)
        asm = dxbc_asm or ''
        n = sum(int(m.group(1)) for m in re.finditer(r'dcl_tgsm_raw\s+g\d+,\s*(\d+)', asm)) + \
            sum(int(m.group(1)) * int(m.group(2)) for m in re.finditer(r'dcl_tgsm_structured\s+g\d+,\s*(\d+),\s*(\d+)', asm))
        f['shared'] = (n + 15) // 16 * 16
        if dxbc_asm is None: f['pc_missing'] = True
    return f

def pairs():
    """映射表（含冲突表的改判）→ {键: (配对的 PC 名, 阶段)} | Mapping table (with the conflict table's overrides) → {key: (paired PC name, stage)}"""
    pc_of, stage_of = {}, {}
    for ln in open(MAP):
        c = ln.rstrip('\n').split('\t')
        if len(c) > 4 and c[0].endswith('.bin'): pc_of.setdefault(c[3], c[4]); stage_of.setdefault(c[3], c[0][:2])
        if len(c) > 4 and c[0].startswith('main.rodata@'): pc_of.setdefault(c[3], c[4]); stage_of[c[3]] = {'顶点': 'vs', '像素': 'ps'}[c[2]]
    for ln in open(MAP + '.conflicts.tsv'):
        c = ln.rstrip('\n').split('\t')
        if len(c) > 1 and not ln.startswith('#') and not ln.startswith('dm_') and c[0] in pc_of: pc_of[c[0]] = c[1]
    return {k: (pc_of[k], stage_of[k]) for k in pc_of}

def recompute():
    pcc = os.environ.get('PCCACHE', f'{DM_ROOT}/build/cache/metal_shader_cache')
    dxdirs = os.environ.get('PCDXBC', f'{DM_ROOT}/build/ios/dxbc_all_0930:{DM_ROOT}/data/d3d12_study/shaders').split(':')
    vk = os.environ.get('VKD3D', f'{DM_ROOT}/build/vkd3d/inst/bin/vkd3d-compiler')
    if not os.path.isdir(pcc): sys.exit(f'【红】没有 PC 反射目录 {pcc}（PCCACHE=）')
    out, missing = {}, 0
    for key, (pc, stage) in sorted(pairs().items()):
        pp = os.path.join(pcc, pc + '.json')
        if not os.path.exists(pp): missing += 1; continue   # 无配对 PC 反射：不进表，查询按缺省 | no paired PC reflection: not entered in the table, queries use defaults
        asm = None
        if stage == 'cs':
            dx = next((p for d in dxdirs for p in (os.path.join(d, pc + '.dxbc'), os.path.join(d, pc[:12] + '.dxbc')) if os.path.exists(p)), None)
            if dx: asm = subprocess.run([vk, '-x', 'dxbc-tpf', '-b', 'd3d-asm', dx], capture_output=True, text=True).stdout
        out[key] = from_pc(json.load(open(pp)), stage, asm)
    return out, missing

if __name__ == '__main__':
    a = sys.argv[1:]
    if a == ['--freeze']:
        t, missing = recompute()
        open(TABLE, 'w').write('# 翻译查询的作答表（dmsh_facts.py --freeze 生成，勿手改）：键 <TAB> 事实 JSON\n' + ''.join(row(k, t[k]) for k in sorted(t)))
        print(f'已写 {TABLE}：{len(t)} 键；无配对 PC 反射、未进表 {missing}')
    elif a == ['--check']:
        t, missing = recompute(); have = load(observed=False)
        bad = sorted(k for k in set(t) | set(have) if t.get(k) != have.get(k))
        for k in bad[:10]: print(f'【红】{k}：表 {have.get(k)} / 重算 {t.get(k)}')
        print(f'逐键比对 {len(set(t) | set(have))}：不一致 {len(bad)}；无配对 PC 反射 {missing}'); sys.exit(1 if bad else 0)
    elif not a:
        t = load(); print(f'{len(t)} 键：' + '，'.join(f'{n} {sum(bool(f.get(n)) for f in t.values())}' for n in ('tex', 'img', 'attr', 'fout', 'local', 'shared', 'pc_missing')))
    elif len(a) == 2 and a[0] == '--fout-merge':
        have, bad, new = read_tsv(FOUT), 0, 0
        if not os.path.exists(a[1]): sys.exit(f'【红】没有 {a[1]}（宿主跑时设 DM_NVN_FOUT_WANT）')
        for ln in open(a[1]):   # 逐行读：同一个键可能记了几行（颜色组合不同） | line by line: one key may have several lines (different color sets)
            if not ln.strip() or ln.startswith('#'): continue
            k, v = ln.rstrip('\n').split('\t', 1); cur = have.setdefault(k, {})
            for c, kind in json.loads(v).items():
                if cur.get(c, kind) != kind: print(f'【红】{k} 颜色 {c}：表里是 {cur[c]}，又观察到 {kind}（同一着色器画两种附件，一张表答不了）'); bad += 1; continue
                new += c not in cur; cur[c] = kind
        open(FOUT, 'w').write('# 运行时观察到的片元输出类型（宿主 DM_NVN_FOUT_WANT → dmsh_facts.py --fout-merge）：键 <TAB> {颜色号: uint|sint} | '
                              'runtime-observed fragment output types (host DM_NVN_FOUT_WANT → dmsh_facts.py --fout-merge): key <TAB> {color: uint|sint}\n' + ''.join(row(k, have[k]) for k in sorted(have)))
        print(f'已写 {FOUT}：{len(have)} 键，新增 {new} 项' + (f'，冲突 {bad} 项' if bad else '')); sys.exit(1 if bad else 0)
    else: sys.exit('用法见文件头')
