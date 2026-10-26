"""Snowdrop WEST/BERG v22 (Switch): indexed resources and NVN cache payloads.

Directory offsets and page lengths come from WEST, never from searching BERG
for compression signatures. Paths are labels only; no resource is written out.
Only the v22/zstd dialect verified on Sparks of Hope is accepted.
"""
from dataclasses import dataclass
from pathlib import Path
import re
import struct

WEST = b'WEST'
BERG = b'BERG'
CACHE = bytes.fromhex('c600cdab')
CTL = bytes.fromhex('34127698')
PAGE = 65536

class FormatError(ValueError):
    pass

def require(ok, message):
    if not ok:
        raise FormatError(message)

def zstd_exact(data, size):
    try:
        from compression import zstd
    except ImportError:
        from backports import zstd
    decoder = zstd.ZstdDecompressor()
    try:
        result = decoder.decompress(data, max_length=size + 1)
    except zstd.ZstdError as e:
        raise FormatError(f'invalid zstd frame: {e}') from e
    require(len(result) == size and decoder.eof and not decoder.unused_data,
            'zstd frame length or boundary mismatch')
    return result

class Cursor:
    def __init__(self, data, pos=0):
        self.data, self.pos = data, pos

    def read(self, size):
        require(0 <= size <= len(self.data) - self.pos, 'truncated WEST directory')
        value = self.data[self.pos:self.pos + size]
        self.pos += size
        return value

    def uint(self, size):
        return int.from_bytes(self.read(size), 'little')

@dataclass(frozen=True)
class Part:
    archive: int
    offset: int
    size: int
    stored: int
    compressed: bool
    pages: tuple

@dataclass(frozen=True)
class Entry:
    name: str
    parts: tuple
    dds: object = None

def directory(data):
    """Return every indexed entry, rejecting truncated/overlapping tree nodes."""
    require(len(data) >= 77, 'truncated WEST header')
    magic, version, raw, stored, first, count, nd = struct.unpack_from('<4s6I', data)
    require(magic == WEST and version == 22, 'unsupported WEST signature/version')
    require(data[28:36] == b'massive\0' and data[68:76] == b'ubisoft\0', 'invalid WEST identity')
    require(data[76] in (0, 1), 'unsupported WEST signature flag')
    start = 77 + data[76] * 320 + count * 52 + nd * 204
    require(raw > 0 and stored > 0 and start + stored + 48 == len(data), 'invalid WEST table/payload lengths')
    require(data[-48:] == data[28:76], 'WEST trailing identity mismatch')
    # Package sizes, 48-byte package identities and 204-byte DDS templates
    # precede the tree. The package ID range starts at `first` (DLCs use it).
    require(first + count <= 65536, 'WEST package ID range overflow')
    templates = []
    for i in range(nd):
        at = 77 + data[76] * 320 + count * 52 + i * 204
        used = struct.unpack_from('<I', data, at)[0]
        require(used <= 200, 'invalid WEST DDS template length')
        templates.append(data[at + 4:at + 4 + used])
    tree = zstd_exact(data[start:start + stored], raw)
    stack = [(0, b'')]; seen = set(); intervals = []; entries = []; names = set()
    while stack:
        at, prefix = stack.pop()
        require(0 <= at < len(tree) and at not in seen, 'WEST cycle or invalid branch offset')
        seen.add(at); c = Cursor(tree, at); tag = c.uint(1)
        if 1 <= tag <= 31:
            name = prefix + c.read(tag)
            require(len(name) <= 65535, 'WEST path too long')
            stack.append((c.pos, name))
        elif 65 <= tag <= 90:
            bits = tag - 65; n = bits & 7; parts = []; template = None
            if n:
                c.uint(4)  # resource stamp, not an offset
                desc = c.uint(1); ti = c.uint(desc & 3)
                if desc & 3:
                    require(ti < len(templates), 'invalid WEST DDS template index')
                    template = templates[ti]
                for _ in range(n):
                    flags = c.uint(1)
                    require(flags < 64, 'unsupported WEST resource flags')
                    ns = (flags & 3) + 1; no = (flags >> 2) & 7
                    size = c.uint(ns); compressed = bool(flags & 32)
                    packed = c.uint(ns) if compressed else size
                    offset = c.uint(no); archive = c.uint(2)
                    require(first <= archive < first + count, 'WEST archive ID outside declared range')
                    pages = tuple(c.uint(2) for _ in range((size + PAGE - 1)//PAGE)) if compressed and size > PAGE else ()
                    if pages:
                        total = sum(n or min(PAGE, size - i*PAGE) for i, n in enumerate(pages))
                        require(total == packed, 'WEST compressed page lengths disagree with resource length')
                    require(offset >= 56 and packed > 0 and size > 0, 'invalid WEST resource extent')
                    parts.append(Part(archive, offset, size, packed, compressed, pages))
                try:
                    name = prefix.decode('utf-8')
                except UnicodeDecodeError as e:
                    raise FormatError('invalid WEST path encoding') from e
                require(name and name not in names and '\0' not in name, 'duplicate or invalid WEST path')
                names.add(name); entries.append(Entry(name, tuple(parts), template))
            if bits & 8:
                c.read(c.uint(1) * 2)  # resource variant pairs
        else:
            require(tag >= 32, 'invalid WEST tree tag')
            jump = c.uint(4)
            stack.append((jump, prefix)); stack.append((c.pos, prefix))
        intervals.append((at, c.pos))
    end = 0
    for a, b in sorted(intervals):
        require(a == end, 'overlapping or unreachable WEST directory data')
        end = b
    require(tree[end:] == b'\0', 'invalid WEST directory terminator')
    return entries

class Archive:
    def __init__(self, toc, entries=None):
        self.toc = Path(toc)
        self.entries = directory(self.toc.read_bytes()) if entries is None else entries
        self.files = {}; self.validated = set()
        pattern = re.compile(re.escape(self.toc.stem) + r'_[A-Z]_(\d+)\.sdfdata$')
        for path in self.toc.parent.glob(self.toc.stem + '_*.sdfdata'):
            m = pattern.fullmatch(path.name)
            if m:
                ident = int(m[1]); require(ident not in self.files, 'duplicate BERG archive ID')
                self.files[ident] = path

    def read(self, entry):
        result = bytearray()
        for part in entry.parts:
            require(part.archive in self.files, f'missing BERG archive {part.archive} for {entry.name}')
            path = self.files[part.archive]
            require(part.offset + part.stored <= path.stat().st_size, f'BERG resource outside archive: {entry.name}')
            with path.open('rb') as f:
                if part.archive not in self.validated:
                    head = f.read(56)
                    require(len(head) == 56 and head[:8] == BERG + struct.pack('<I', 22)
                            and head[8:16] == b'massive\0' and head[48:56] == b'ubisoft\0', 'invalid BERG header/version')
                    self.validated.add(part.archive)
                f.seek(part.offset); data = f.read(part.stored)
            require(len(data) == part.stored, 'truncated BERG resource')
            if not part.compressed:
                result.extend(data); continue
            pos = 0
            for i, packed in enumerate(part.pages or (part.stored,)):
                raw = min(PAGE, part.size - i*PAGE); packed = packed or raw
                chunk = data[pos:pos + packed]; pos += packed
                require(len(chunk) == packed, 'truncated BERG page')
                result.extend(chunk if packed == raw else zstd_exact(chunk, raw))
            require(pos == len(data), 'unused BERG compressed bytes')
        require(len(result) == sum(p.size for p in entry.parts), 'BERG decoded resource length mismatch')
        return bytes(result)

def cache_shaders(data):
    """NVN mcache: validated wrapper, then size-delimited control/code blobs.

    A serialized shader blob stores its total length immediately before CTL;
    CTL declares both its own size and its code size. All three must agree.
    Return records in serialization order; shader_split performs stage checks.
    """
    require(len(data) >= 20 and data[:4] == CACHE, 'invalid NVN mcache header')
    if struct.unpack_from('<I', data, 8)[0] == 0:
        raw, stored = struct.unpack_from('<2I', data, 12)
        require(stored == len(data) - 20, 'NVN mcache compressed extent mismatch')
        data = zstd_exact(data[20:], raw)
    require(len(data) >= 20 and data[:4] == CACHE and data[-4:] == CACHE, 'invalid NVN mcache body')
    records = []; pos = 0
    while True:
        at = data.find(CTL, pos)
        if at < 0:
            break
        require(at >= 4 and at + 0x880 <= len(data), 'truncated NVN control section')
        nc = struct.unpack_from('<I', data, at + 0x20)[0]
        nk = struct.unpack_from('<I', data, at + 0x704)[0]
        require(nc == 0x880 and nk >= 0x50 and at + nc + nk <= len(data), 'invalid NVN shader lengths')
        require(struct.unpack_from('<I', data, at - 4)[0] == nc + nk, 'NVN serialized shader extent mismatch')
        ctl = data[at:at + nc]; code = data[at + nc:at + nc + nk]
        require(code[:4] in (bytes.fromhex('78563412'), bytes.fromhex('79563412')), 'invalid NVN code header')
        records.append((ctl, code)); pos = at + nc + nk
    require(records, 'NVN mcache contains no shaders')
    return records
