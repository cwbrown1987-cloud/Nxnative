# Chapter 3: Troubleshooting & Bug Fixes

This chapter documents all real-world issues encountered during the native porting project, providing technical post-mortems, root-cause analyses, and exact code diffs.

---

## Issue 1: Missing Xcode Metal Toolchain

### Symptoms
When running `dmsh_build.py` (Stage 5), shader compilation aborted immediately:
```text
xcrun: error: unable to find utility "metal", not a developer tool or in PATH
```

### Root Cause
Apple decoupled standalone Metal compilation utilities (`metal`, `metallib`) from Command Line Tools in Xcode 15/16.

### Solution
Download and register the official Metal component:
```bash
xcodebuild -downloadComponent MetalToolchain
```
Verify with: `xcrun -sdk macosx metal -v`.

---

## Issue 2: .NET SDK Host Resolution

### Symptoms
`build_ipa_from_nsp.py` failed during Stage 1 (`build nx_extract`) with:
```text
The command could not be loaded, possibly because:
  * You intended to execute a .NET application:
      The application 'nx_extract.dll' does not exist.
  * You intended to execute a .NET SDK command:
      No .NET SDKs were found.
```

### Root Cause
Homebrew on Apple Silicon installs the .NET SDK into `/opt/homebrew/opt/dotnet/libexec`. Without `DOTNET_ROOT` exported, the `dotnet` binary multiplexer cannot locate SDK runtimes.

### Solution
Export `DOTNET_ROOT` in environment and build scripts:
```bash
export DOTNET_ROOT="/opt/homebrew/opt/dotnet/libexec"
export PATH="$DOTNET_ROOT:$PATH"
```

---

## Issue 3: Stale Translation Chain Version

### Symptoms
Stage 5 shader build reported:
```text
translation chain mismatch: game profile specifies b-ef267d8c3195, host header has b-1981b...
```

### Root Cause
`nxnative/dm/host/dmsh_chain.h` was generated against an older build of the translation tools.

### Solution
Regenerate the header against the active translation binaries:
```bash
python3 nxnative/dm/gfx/tools/dmsh_chain.py --header > nxnative/dm/host/dmsh_chain.h
```

---

## Issue 4: Missing `c1_full.tsv` Guard Table

### Symptoms
Stage 6 failed while copying profile tables:
```text
cp: /Volumes/RAGHAV SSD/nintendo/nxnative/dm/games/010003F003A34000/c1_full.tsv: No such file or directory
```

### Root Cause
`build_ipa.sh` expects `c1_full.tsv` (the table of unbounded constant buffers) in the profile folder for NVN games.

### Solution
Generate `c1_full.tsv` using `c1_guard.py`:
```bash
python3 nxnative/dm/gfx/tools/c1_guard.py \
  "/Volumes/RAGHAV SSD/nintendo/PokemonLetsGoPikachu/010003F003A34000_build/shader/ios/b-ef267d8c3195" \
  "/Volumes/RAGHAV SSD/nintendo/nxnative/dm/games/010003F003A34000/c1_full.tsv"
```

---

## Issue 5: `build_ipa.sh` Path-with-Spaces Breakage

### Symptoms
Stage 6 succeeded in Xcode (`** BUILD SUCCEEDED **`), but `build_ipa.sh` exited with:
```text
[05:38:11] FAIL: no built app
```

### Root Cause
In `nxnative/dm/ios/tools/build_ipa.sh` (line 72):
```bash
APP=$DD/Build/Products/Release-iphoneos/DmIOS.app; [ -d "$APP" ] || APP=$(grep -o '/[^ ]*/Release-iphoneos/DmIOS\.app' "$O/build.log" | tail -1)
```
The regex `/[^ ]*/Release-iphoneos/DmIOS\.app` excludes spaces (`[^ ]*`). When building on an external drive with spaces in its name (`/Volumes/RAGHAV SSD/`), the regex truncated at the space, producing:
```text
/Xcode/DerivedData/Build/Products/Release-iphoneos/DmIOS.app
```
which did not exist.

### Solution
Replace the regex with a robust Python path extractor that handles escaped and unescaped spaces:
```bash
# In nxnative/dm/ios/tools/build_ipa.sh:
APP=$DD/Build/Products/Release-iphoneos/DmIOS.app
if [ ! -d "$APP" ]; then
  APP=$(python3 -c '
import os, re, sys
found = ""
with open(sys.argv[1]) as f:
    for line in f:
        line = line.replace("\\ ", " ")
        m = re.search(r"(/[^:\n\r\t]+?/Release-iphoneos/DmIOS\.app)", line)
        if m:
            p = m.group(1).strip()
            if os.path.isdir(p):
                found = p
if found:
    print(found)
' "$O/build.log")
fi
[ -n "$APP" ] && [ -d "$APP" ] || die "no built app"; t "app: $APP"
```

---

## Issue 6: Poké Ball Plus ("Palma") Startup Abort

### Symptoms
Game crashed immediately during boot:
```text
[dm] SVC 0x1f x0=0x1733a2028 x1=0x10a9f4f0d x2=0 (placeholder returns success)
[dm] SVC 0x21 x0=0xa9f4f0d x1=0x783aca4600 x2=0xa9f4f0d (placeholder returns success)
[dm] Break#1 reason=0 Result=0 svc at sdk+0xd989c
[dm] bt: sdk+0x4c780 sdk+0x4c844 sdk+0x4c8e0 sdk+0xd989c ...
```

### Root Cause
*Pokémon: Let's Go* initializes Poké Ball Plus hardware (`nn::hid::SetPalmaBoostMode`, `InitializePalma`, `EnableAnyPalmaConnection`). When unhooked, the SDK attempted IPC to the Switch Service Manager (`sm:`), which does not exist on macOS, triggering an assertion failure.

### Solution
Add `HLE_FORCE` hooks in `nxnative/dm/host/hle_hid.c`:
```c
HLE_FORCE("_ZN2nn3hid17SetPalmaBoostModeEb", "palma boost mode (pokeball plus) no-op", Result, h_hid_SetPalmaBoostMode, bool on) { (void)on; return RES_OK; }
HLE_FORCE("_ZN2nn3hid15InitializePalmaERKNS0_21PalmaConnectionHandleE", "initialize palma", Result, h_hid_InitPalma, const void *h) { (void)h; return RES_OK; }
HLE_FORCE("_ZN2nn3hid24EnableAnyPalmaConnectionEv", "enable any palma connection", Result, h_hid_EnableAnyPalma, void) { return RES_OK; }
HLE_FORCE("_ZN2nn3hid25DisableAnyPalmaConnectionEv", "disable any palma connection", Result, h_hid_DisableAnyPalma, void) { return RES_OK; }
HLE_FORCE("_ZN2nn3hid27EnablePairedPalmaConnectionEv", "enable paired palma connection", Result, h_hid_EnablePairedPalma, void) { return RES_OK; }
HLE_FORCE("_ZN2nn3hid28DisablePairedPalmaConnectionEv", "disable paired palma connection", Result, h_hid_DisablePairedPalma, void) { return RES_OK; }
HLE_FORCE("_ZN2nn3hid24GetPalmaConnectionHandleEPNS0_21PalmaConnectionHandleERKj", "get palma connection handle: none", Result, h_hid_GetPalmaHandle, void *h, const uint32_t *npad_id) { (void)h; (void)npad_id; return 0x20ca; }
HLE_FORCE("_ZN2nn3hid12GetNpadStateEPNS0_14NpadPalmaStateERKj", "palma controller current state (not connected)", void, h_hid_StatePalma, NpadState *s, const uint32_t *id) { (void)id; memset(s, 0, sizeof(*s)); }
HLE_FORCE("_ZN2nn3hid13GetNpadStatesEPNS0_14NpadPalmaStateEiRKj", "palma controller states: 0", int, h_hid_StatesPalma, NpadState *s, int n, const uint32_t *id) { (void)s; (void)n; (void)id; return 0; }
```

---

## Issue 7: C Compiler Error: `unknown type name 'bool'`

### Symptoms
When compiling `dmhost` after adding the Palma stubs:
```text
hle_hid.c:212:121: error: unknown type name 'bool'
```

### Root Cause
`hle_hid.c` is compiled as C99/C11. The `bool` keyword requires `<stdbool.h>`, which was not included in that translation unit.

### Solution
Include `<stdbool.h>` at the top of `hle_hid.c`:
```c
#include "hle.h"
#include "dm_input.h"
#include "front.h"
#include <stdbool.h>
#include <stdatomic.h>
```

---

## Issue 8: Bluetooth Low Energy (BLE / GATT) Startup Assertion

### Symptoms
Even after stubbing Palma, the game aborted at `sdk+0xd989c` with the backtrace:
```text
sdk+0x251cdc: _ZN2nn9bluetooth13InitializeBleEv+0xc
sdk+0x250138: _ZN2nn9bluetooth4user32InitializeBluetoothUserInterfaceEv+0x28
sdk+0xc0470:  _ZN2nn2sf4hipc31InitializeHipcServiceResolutionEv+0x10
sdk+0xc07f4:  _ZN2nn2sm10InitializeEv+0x1c4
sdk+0x4c8e0:  _ZN2nn4diag6detail18OnAssertionFailure...
```

### Root Cause
The game initializes Bluetooth for Pokémon GO mobile connectivity. Unhooked `InitializeBle()` reached the guest SDK's IPC layer, which asserted when `sm:` was unavailable. Furthermore, the engine immediately attempts to acquire 5 `SystemEventType` synchronization events.

### Solution
Implement HLE hooks in `nxnative/dm/host/hle_offline.c` that return `RES_OK` and bind the guest events to kernel events using `hle_bind_system_event(ev, 0)`:
```c
HLE_FORCE("_ZN2nn9bluetooth13InitializeBleEv", "bluetooth BLE init: returns success", Result, h_bt_InitBle, void) { return RES_OK; }
HLE_FORCE("_ZN2nn9bluetooth19AcquireBleScanEventEPNS_2os15SystemEventTypeE", "bluetooth scan event", Result, h_bt_ScanEv, void *ev) { hle_bind_system_event(ev, 0); return RES_OK; }
HLE_FORCE("_ZN2nn9bluetooth37AcquireBleConnectionStateChangedEventEPNS_2os15SystemEventTypeE", "bluetooth conn event", Result, h_bt_ConnEv, void *ev) { hle_bind_system_event(ev, 0); return RES_OK; }
HLE_FORCE("_ZN2nn9bluetooth31AcquireBleServiceDiscoveryEventEPNS_2os15SystemEventTypeE", "bluetooth discovery event", Result, h_bt_ServEv, void *ev) { hle_bind_system_event(ev, 0); return RES_OK; }
HLE_FORCE("_ZN2nn9bluetooth24AcquireBleMtuConfigEventEPNS_2os15SystemEventTypeE", "bluetooth mtu event", Result, h_bt_MtuEv, void *ev) { hle_bind_system_event(ev, 0); return RES_OK; }
HLE_FORCE("_ZN2nn9bluetooth28AcquireBleGattOperationEventEPNS_2os15SystemEventTypeE", "bluetooth gatt event", Result, h_bt_GattEv, void *ev) { hle_bind_system_event(ev, 0); return RES_OK; }
HLE_FORCE("_ZN2nn9bluetooth23StartBleScanSmartDeviceERKNS0_17GattAttributeUuidE", "bluetooth scan", Result, h_bt_StartScan, const void *u) { (void)u; return RES_OK; }
HLE_FORCE("_ZN2nn9bluetooth22StopBleScanSmartDeviceEv", "bluetooth stop scan", Result, h_bt_StopScan, void) { return RES_OK; }
HLE_FORCE("_ZN2nn9bluetooth16GetBleScanResultEPNS0_13BleScanResultEi", "bluetooth scan results: 0", int, h_bt_GetScanResult, void *r, int m) { (void)r; (void)m; return 0; }
```

---

## Issue 9: Keyboard Unresponsive in Docked Mode

### Symptoms
The game booted to the title screen, but pressing keyboard keys (`W`, `A`, `S`, `D`, `J`, `K`) produced no response.

### Root Cause
1. `dmhost` defaulted to Docked/Console mode (`DM_OPMODE=1`).
2. *Pokémon: Let's Go* explicitly rejects Pro Controllers (`STYLE_FULLKEY`) in Docked mode, requiring a single Joy-Con or Poké Ball Plus.
3. `hle_hid.c` only reported `STYLE_FULLKEY` in Docked mode, causing `fill()` to return attributes = 0 (unconnected).

### Solution
1. Default to Handheld mode (`export DM_OPMODE="${DM_OPMODE:-0}"`) in runner scripts. Handheld mode natively enables full button and analog controls.
2. In `hle_hid.c`, allow `fill()` to supply inputs regardless of whether the game queries `STYLE_HANDHELD`, `STYLE_JOYRIGHT`, or `STYLE_FULLKEY`.
3. In `front_mac.m`, expand key mappings to support `Space`, `Return`, `X`, `M`, `Escape`, and arrow keys.
