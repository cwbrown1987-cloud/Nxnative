# Chapter 4: Reverse Engineering & HLE Stubs

When porting a new game, startup crashes are almost always caused by unhandled Switch SDK functions attempting IPC calls to Horizon OS services (`sm:`). This chapter details the reverse-engineering methodology used to isolate, decode, and stub missing services.

---

## 1. Decompressing and Parsing NSO Binaries

Nintendo Switch executables in `ExeFS/` (`main`, `sdk`, `subsdk*`) are packaged as compressed NSO binaries (`NSO0` magic).

### Python NSO Loader Script
The following Python routine decompresses an NSO into its raw virtual memory layout:

```python
import struct, lz4.block

def load_nso(path):
    d = open(path, "rb").read()
    assert d[:4] == b"NSO0", "Not an NSO file"
    flags = struct.unpack_from("<I", d, 0x0c)[0]
    # Segments: 0 = .text, 1 = .rodata, 2 = .data
    segs = [struct.unpack_from("<III", d, 0x10 + i * 0x10) for i in range(3)]
    csz = struct.unpack_from("<III", d, 0x60)
    bss_sz = struct.unpack_from("<I", d, 0x3c)[0]
    
    total_sz = segs[2][1] + segs[2][2] + bss_sz
    img = bytearray(total_sz)
    
    for i, (fo, mo, sz) in enumerate(segs):
        raw = d[fo:fo + csz[i]]
        if (flags >> i) & 1:  # Compressed flag
            raw = lz4.block.decompress(raw, uncompressed_size=sz)
        img[mo:mo + sz] = raw
    return bytes(img)
```

---

## 2. Dynamic Symbol Extraction

NSO binaries include a dynamic symbol table (`.dynsym` and `.dynstr`) located via the embedded `MOD0` header:

```python
def extract_dynsyms(img):
    mod0_off = struct.unpack_from("<I", img, 4)[0]
    assert img[mod0_off:mod0_off + 4] == b"MOD0"
    dyn_off = mod0_off + struct.unpack_from("<i", img, mod0_off + 4)[0]
    
    tags = {}
    for i in range(4096):
        tag, val = struct.unpack_from("<qQ", img, dyn_off + i * 16)
        if tag == 0: break
        tags[tag] = val
        
    symtab, strtab = tags[6], tags[5]
    n = (strtab - symtab) // 24
    if 4 in tags:  # DT_HASH
        n = struct.unpack_from("<I", img, tags[4] + 4)[0]
        
    symbols = []
    for i in range(1, n):
        name_idx, info, other, shndx, value, size = struct.unpack_from("<IBBHQQ", img, symtab + i * 24)
        name = img[strtab + name_idx:img.index(b"\0", strtab + name_idx)].decode("latin1")
        if name:
            symbols.append({"name": name, "value": value, "size": size, "defined": shndx != 0})
    return symbols
```

---

## 3. Crash Backtrace Decoding

When a crash occurs, `dmhost` prints a register dump and a call stack:
```text
[dm] Break#1 reason=0 Result=0 svc at sdk+0xd989c
[dm] bt: sdk+0x4c780 sdk+0x4c844 sdk+0x4c8e0 sdk+0xc07f4 sdk+0xc0470 sdk+0x250138 sdk+0x251cdc main+0x1139d4 ...
```

### Symbol Resolution Procedure
Run this Python snippet against the extracted `sdk` and `main` NSOs:

```python
def resolve_address(symbols, target_addr):
    closest = None
    for sym in sorted(symbols, key=lambda s: s["value"]):
        if sym["value"] <= target_addr:
            closest = sym
        else:
            break
    if closest:
        return f"{closest['name']} + {target_addr - closest['value']:#x}"
    return f"unknown ({target_addr:#x})"

# Example output:
# sdk+0x251cdc -> _ZN2nn9bluetooth13InitializeBleEv + 0xc
# sdk+0x250138 -> _ZN2nn9bluetooth4user32InitializeBluetoothUserInterfaceEv + 0x28
# sdk+0xc0470  -> _ZN2nn2sf4hipc31InitializeHipcServiceResolutionEv + 0x10
# sdk+0xc07f4  -> _ZN2nn2sm10InitializeEv + 0x1c4
# sdk+0x4c8e0  -> _ZN2nn4diag6detail18OnAssertionFailure...
```

**Interpretation:**
- `main` called `InitializeBle()`.
- `InitializeBle()` reached `InitializeHipcServiceResolution()` -> `nn::sm::Initialize()`.
- `sm::Initialize()` aborted with an assertion failure because the Horizon Service Manager is absent.

---

## 4. Disassembling Call Sites with Capstone

To see what arguments and return types a function expects, disassemble the call site:

```python
import capstone

md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
# Disassemble main at 0x1139d0
for insn in md.disasm(main_img[0x1139d0:0x113a00], 0x1139d0):
    print(f"{insn.address:#x}: {insn.mnemonic} {insn.op_str}")

# Disassembly:
# 0x1139d0: bl #0xd30438    -> Call InitializeBle()
# 0x1139d4: mov x0, x24
# 0x1139d8: bl #0xd30448    -> Call AcquireBleScanEvent(x24)
# 0x1139dc: mov x0, x23
# 0x1139e0: bl #0xd30458    -> Call AcquireBleConnectionStateChangedEvent(x23)
```
*Note: Registers `x24`, `x23`, `x22`, `x21`, `x20` passed to `bl` instructions are pointers to `nn::os::SystemEventType` objects.*

---

## 5. Implementing HLE Hooks

### The `HLE_FORCE` Macro
Defined in `nxnative/dm/host/hle.h`:
```c
HLE_FORCE("mangled_symbol_name", "human description", ReturnType, func_name, arg1_type arg1, ...) {
    // implementation
}
```

### Binding `SystemEventType` Events
Many Switch services require event handles for asynchronous notification. The host cannot leave these pointers uninitialized:

```c
// Mandatory: Bind the guest SystemEventType to a kernel event on the guest thread
hle_bind_system_event(void *ev, int autoclear);

// Optional: Signal the event if immediate notification is required
hle_signal_system_event(void *ev);
```

#### Example Implementation
```c
HLE_FORCE("_ZN2nn9bluetooth19AcquireBleScanEventEPNS_2os15SystemEventTypeE", 
          "bluetooth scan event", 
          Result, 
          h_bt_ScanEv, 
          void *ev) {
    hle_bind_system_event(ev, 0); // 0 = manual clear, 1 = auto clear
    return RES_OK;
}
```
