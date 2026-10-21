# Chapter 6: Fast-Track Porting Cheat Sheet

A condensed, copy-paste reference guide for porting future Nintendo Switch titles to macOS and iOS using `nxnative`.

---

## 1. Environment & One-Time Setup

```bash
# 1. Install CLI tools
brew install dotnet-sdk xcodegen spirv-cross
pip3 install lz4 capstone fonttools

# 2. Install Apple Metal Toolchain (Xcode 15/16)
xcodebuild -downloadComponent MetalToolchain

# 3. Configure .NET SDK environment
export DOTNET_ROOT="/opt/homebrew/opt/dotnet/libexec"
export PATH="$DOTNET_ROOT:$PATH"
```

---

## 2. Fast Build Pipeline One-Liner

```bash
# Run the complete 7-stage pipeline
python3 nxnative/scripts/build_ipa_from_nsp.py \
  "/path/to/GameFolder" \
  -k "/path/to/keys/prod.keys"
```

---

## 3. Rebuilding the Native macOS Host (`dmhost`)

Whenever modifying `front_mac.m`, `hle_hid.c`, or any other HLE files:

```bash
# Rebuild dmhost
make -C nxnative/dm/host GAME=<TitleID> dmhost

# If make does not detect changes, force recompile:
rm -f nxnative/dm/host/dmhost
make -C nxnative/dm/host GAME=<TitleID> dmhost
```

---

## 4. Headless Automated Boot Verification

Test that a port boots, initializes GPU, binds shaders, and runs stably without opening a GUI window:

```bash
python3 -c '
import subprocess, os

cmd = ["nxnative/dm/host/dmhost", "/path/to/patched_v<version>"]
env = os.environ.copy()
env.update({
    "DM_WINDOW": "0",
    "DM_AUDIO": "0",
    "DM_OPMODE": "0",
    "DM_ROOT": "/path/to/build_dir",
    "DM_ROMFS": "/path/to/build_dir/extract/v<version>/RomFS",
    "DM_SAVE": "/path/to/build_dir/run/save",
    "DM_TEMP": "/path/to/build_dir/run/temp",
    "DM_MSL_DIR": "/path/to/build_dir/shader/ios",
    "DM_FONT_DIR": "/path/to/build_dir/font"
})
try:
    p = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=8)
    print("Exited with code:", p.returncode)
    print(p.stdout[-2000:])
except subprocess.TimeoutExpired as e:
    print("✓ Success! Game booted and ran stable frame loop for 8 seconds.")
'
```

---

## 5. Simulating Keypresses (`DM_KEYS`)

To script automated button presses (e.g. Press A at 1s, 2s, 3s):

```bash
DM_KEYS="1:A,2:A,3:A" ./run_mac.sh
```

Supported button names in `DM_KEYS`:
`A`, `B`, `X`, `Y`, `LS`, `RS`, `L`, `R`, `ZL`, `ZR`, `Plus`, `Minus`, `Left`, `Up`, `Right`, `Down`, `LLeft`, `LUp`, `LRight`, `LDown`, `RLeft`, `RUp`, `RRight`, `RDown`.

---

## 6. Fast Symbol Lookup & Backtrace Resolver

If a new game crashes at `sdk+0x<hex>` or `main+0x<hex>`, resolve it immediately:

```bash
python3 -c '
import struct, lz4.block, sys

def get_syms(nso_path):
    d = open(nso_path, "rb").read()
    flags = struct.unpack_from("<I", d, 0xc)[0]
    segs = [struct.unpack_from("<III", d, 0x10 + i * 0x10) for i in range(3)]
    csz = struct.unpack_from("<III", d, 0x60)
    img = bytearray(segs[2][1] + segs[2][2] + struct.unpack_from("<I", d, 0x3c)[0])
    for i, (fo, mo, sz) in enumerate(segs):
        raw = d[fo:fo + csz[i]]
        if flags >> i & 1: raw = lz4.block.decompress(raw, uncompressed_size=sz)
        img[mo:mo + sz] = raw
    mod0 = struct.unpack_from("<I", img, 4)[0]
    dyn = mod0 + struct.unpack_from("<i", img, mod0 + 4)[0]
    tags = {}
    for i in range(4096):
        t, v = struct.unpack_from("<qQ", img, dyn + i * 16)
        if t == 0: break
        tags.setdefault(t, v)
    symtab, strtab = tags[6], tags[5]
    n = struct.unpack_from("<I", img, tags[4] + 4)[0] if 4 in tags else (strtab - symtab) // 24
    symbols = []
    for i in range(1, n):
        name, info, other, shndx, value, size = struct.unpack_from("<IBBHQQ", img, symtab + i * 24)
        s = img[strtab + name:img.index(b"\0", strtab + name)].decode("latin1")
        if s: symbols.append((value, s))
    symbols.sort(key=lambda x: x[0])
    return symbols

def lookup(syms, addr):
    m = None
    for val, name in syms:
        if val <= addr: m = (val, name)
        else: break
    return f"{m[1]}+{addr-m[0]:#x}" if m else "unknown"

# Usage: python3 script.py <nso_file> <target_hex_offset>
target = int(sys.argv[2], 16)
print(lookup(get_syms(sys.argv[1]), target))
' /path/to/sdk 0xd989c
```

---

## 7. Clean Rebuild vs. Cache Preservation

| Action | What to Delete | What to Keep |
| :--- | :--- | :--- |
| **Quick Rebuild (Keep Shaders & Extraction)** | `rm -rf <id>_build/ipa <id>_build/logs` | Keeps `extract/` and `shader/` (rebuild takes ~10 seconds). |
| **Re-run Rewriter & Code Patching** | `rm -rf <id>_build/patched_* <id>_build/ipa` | Keeps `extract/` and `shader/`. |
| **Full Clean Rebuild from Scratch** | `rm -rf <id>_build/` | Reprocesses everything from base game files. |
