# Nintendo Switch to Apple Silicon (macOS & iOS) Porting Playbook

Welcome to the **Nintendo Switch Native Porting Playbook**. This repository contains the distilled engineering knowledge, architectural blueprints, bug-fix case studies, and fast-track procedures developed while porting commercial Nintendo Switch titles (specifically *Pokémon: Let's Go, Pikachu!* v1.0.2) to Apple Silicon Macs (macOS) and iOS devices using the `nxnative` static rewriter and High-Level Emulation (HLE) engine.

---

## Table of Contents

1. [Architectural Overview](#architectural-overview)
2. [Fast-Track Porting Quickstart](#fast-track-porting-quickstart)
3. [Playbook Documentation Modules](#playbook-documentation-modules)
4. [Master Troubleshooting Index](#master-troubleshooting-index)
5. [Key File Paths Reference](#key-file-paths-reference)

---

## Architectural Overview

Unlike traditional emulators (Ryujinx, Yuzu) that dynamically interpret or JIT-recompile ARM64 machine code and emulate the Switch operating system (Horizon OS) at run time, `nxnative` operates as a **Static Binary Translator and Native Rehoster**:

```
+-------------------------------------------------------------+
|              Original Game Dumps (.xci / .nsp)              |
+-------------------------------------------------------------+
                              |
                              v  [Stage 1 & 2: nx_extract]
+-------------------------------------------------------------+
|    Extracted NSO Binaries (main, sdk, subsdk*) & RomFS      |
+-------------------------------------------------------------+
                              |
                              v  [Stage 3: patch_nso.py]
+-------------------------------------------------------------+
|  AArch64 Static Rewriter: Patches x18 register, TLS,        |
|  svc hooks, gates, and relocation fixups into native Mach-O |
+-------------------------------------------------------------+
                              |
                              v  [Stage 4 & 5: dmsh_chain / Metal]
+-------------------------------------------------------------+
| NVN / SPIR-V Shaders -> Metal Shading Language (.metallib)  |
+-------------------------------------------------------------+
                              |
                              v  [Stage 6 & 7: Xcode / Clang]
+-------------------------------------------------------------+
|                 Native Host Executables                     |
|  - macOS: dmhost runner + Cocoa Window + Metal Presenter    |
|  - iOS: DmIOS.app embedded Mach-O + packed IPA              |
+-------------------------------------------------------------+
```

### Key Advantages
- **Bare-Metal Performance:** Native ARM64 execution on Apple Silicon (M1/M2/M3/M4) without JIT overhead or VM memory translation.
- **Direct GPU Mapping:** NVN graphics commands are directly translated into Metal 3 API calls with hardware-accelerated texture deswizzling and precompiled pipeline state objects.
- **Zero OS Emulation Overhead:** Switch SDK system calls are intercepted at link/load time and redirected to lightweight host C/Objective-C High-Level Emulation (HLE) stubs.

---

## Fast-Track Porting Quickstart

To port any new Nintendo Switch title in the future:

1. **Place Game Files and Keys:**
   ```bash
   mkdir -p /path/to/game
   # Copy base (.xci / .nsp) and update (.nsp) into /path/to/game
   # Ensure prod.keys is at /path/to/keys/prod.keys
   ```

2. **Run Automated Analysis & Build Pipeline:**
   ```bash
   export DOTNET_ROOT="/opt/homebrew/opt/dotnet/libexec"
   python3 nxnative/scripts/build_ipa_from_nsp.py /path/to/game -k /path/to/keys/prod.keys
   ```

3. **Verify Survey & Profile:**
   - Review `/path/to/game/<TitleID>_survey/survey.md`.
   - Ensure the generated profile in `nxnative/dm/games/<TitleID>/` includes all modules, NVN layout, and shader mappings.

4. **Compile Mac Runner (`dmhost`):**
   ```bash
   make -C nxnative/dm/host GAME=<TitleID> dmhost
   ```

5. **Launch Native macOS App:**
   ```bash
   ./run_mac.sh
   # Or double-click the generated macOS .app bundle
   ```

---

## Playbook Documentation Modules

Detailed guides are split into modular chapters for quick access:

- [**01. Prerequisites & Toolchain Setup**](file:///Volumes/RAGHAV%20SSD/nintendo/port-playbook/01-prerequisites-and-toolchain.md): Xcode, Apple Metal Toolchain, .NET 10 SDK, SPIRV-Cross, Homebrew packages, and environment exports.
- [**02. Pipeline & Build Stages**](file:///Volumes/RAGHAV%20SSD/nintendo/port-playbook/02-pipeline-and-build-stages.md): Breakdown of the 7 stages from extraction through rewriting, shader generation, Xcode compilation, and IPA bundling.
- [**03. Troubleshooting & Bug Fixes**](file:///Volumes/RAGHAV%20SSD/nintendo/port-playbook/03-troubleshooting-and-bug-fixes.md): Exhaustive post-mortems of every real error encountered (path spaces, Palma stubs, BLE assertion failures, C boolean headers, etc.) with code diffs.
- [**04. Reverse Engineering & HLE Stubs**](file:///Volumes/RAGHAV%20SSD/nintendo/port-playbook/04-reverse-engineering-and-hle-stubs.md): Step-by-step methodology using Python, Capstone disassembler, ELF/NSO symbol tables, GOT inspection, and `hle_bind_system_event`.
- [**05. Input, Graphics & App Bundling**](file:///Volumes/RAGHAV%20SSD/nintendo/port-playbook/05-input-graphics-and-app-bundling.md): Controller styles (`STYLE_HANDHELD` vs `STYLE_FULLKEY`), keyboard latching in `front_mac.m`, Metal shader paths, and macOS `.app` packaging with Retina `.icns`.
- [**06. Fast-Track Porting Cheat Sheet**](file:///Volumes/RAGHAV%20SSD/nintendo/port-playbook/06-fast-track-porting-cheatsheet.md): Copy-paste scripts, CLI one-liners, and automated verification tests for future ports.

---

## Master Troubleshooting Index

| Symptom / Error Message | Root Cause | Solution Document |
| :--- | :--- | :--- |
| `xcrun: error: unable to find utility "metal"` | Missing Xcode Metal Toolchain component | [01-prerequisites-and-toolchain.md](file:///Volumes/RAGHAV%20SSD/nintendo/port-playbook/01-prerequisites-and-toolchain.md#1-metal-toolchain-installation) |
| `dotnet: command not found` or library path error | Missing `DOTNET_ROOT` export on macOS | [01-prerequisites-and-toolchain.md](file:///Volumes/RAGHAV%20SSD/nintendo/port-playbook/01-prerequisites-and-toolchain.md#2-dotnet-sdk-configuration) |
| `cannot open .../c1_full.tsv: No such file` | Unbounded shader guard table ungenerated | [02-pipeline-and-build-stages.md](file:///Volumes/RAGHAV%20SSD/nintendo/port-playbook/02-pipeline-and-build-stages.md#stage-4-c1-shader-guard-generation) |
| `FAIL: no built app` in `build_ipa.sh` | Regex path parser broke on space (`/Volumes/RAGHAV SSD/`) | [03-troubleshooting-and-bug-fixes.md](file:///Volumes/RAGHAV%20SSD/nintendo/port-playbook/03-troubleshooting-and-bug-fixes.md#issue-5-build_ipash-path-with-spaces-breakage) |
| `error: unknown type name 'bool'` in `hle_hid.c` | Standard boolean header missing in C translation unit | [03-troubleshooting-and-bug-fixes.md](file:///Volumes/RAGHAV%20SSD/nintendo/port-playbook/03-troubleshooting-and-bug-fixes.md#issue-7-c-compiler-error-unknown-type-name-bool) |
| `Break#1 reason=0 Result=0 svc at sdk+0xd989c` | Unhooked service (Palma / Bluetooth) calling `sm:` | [03-troubleshooting-and-bug-fixes.md](file:///Volumes/RAGHAV%20SSD/nintendo/port-playbook/03-troubleshooting-and-bug-fixes.md#issue-6-palma-and-bluetooth-startup-abort) |
| Game boots but keyboard does nothing | Docked mode (`DM_OPMODE=1`) rejected by game; only accepts Handheld | [05-input-graphics-and-app-bundling.md](file:///Volumes/RAGHAV%20SSD/nintendo/port-playbook/05-input-graphics-and-app-bundling.md#controller-styles-and-operation-modes) |
| Shaders fail to load: `.../b-xxx/b-xxx does not exist` | `DM_MSL_DIR` pointed at subfolder instead of parent | [05-input-graphics-and-app-bundling.md](file:///Volumes/RAGHAV%20SSD/nintendo/port-playbook/05-input-graphics-and-app-bundling.md#metal-shader-directory-convention) |

---

## Key File Paths Reference

- **Working Directory:** `/Volumes/RAGHAV SSD/nintendo/`
- **nxnative Framework:** `/Volumes/RAGHAV SSD/nintendo/nxnative/`
  - Host Core: `nxnative/dm/host/`
  - Graphics / Metal: `nxnative/dm/gfx/`
  - Game Profiles: `nxnative/dm/games/`
  - Toolchain & Scripts: `nxnative/dm/tools/` and `nxnative/scripts/`
- **Game Build Artifacts:** `/Volumes/RAGHAV SSD/nintendo/PokemonLetsGoPikachu/010003F003A34000_build/`
- **Playbook Docs:** `/Volumes/RAGHAV SSD/nintendo/port-playbook/`
