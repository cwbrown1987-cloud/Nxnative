# Chapter 2: Pipeline & Build Stages

The native porting workflow converts raw Nintendo Switch packages into runnable binaries through an automated 7-stage pipeline driven by `nxnative/scripts/build_ipa_from_nsp.py`. This chapter explains each stage in detail.

---

## The 7 Pipeline Stages

```
[1/7] build nx_extract
       |
[2/7] extract game files (v0 base + update NSP)
       |
[3/7] rewrite code modules (patch_nso.py)
       |
[4/7] shader split & table verification (shader_split.py)
       |
[5/7] compile Metal shader libraries (dmsh_build.py)
       |
[6/7] app build (Xcode / Clang)
       |
[7/7] pack IPA / package deliverables (pack_ipa.py)
```

---

### Stage 1: Build `nx_extract`
- **Tool:** .NET Core (`dotnet build -c Release dm/tools/nx_extract/nx_extract.csproj`)
- **Action:** Compiles the high-speed C# Switch PFS0/NCA/XCI extraction utility.
- **Output:** `dm/tools/nx_extract/bin/Release/net10.0/nx_extract.dll`

---

### Stage 2: Game Extraction
- **Action:**
  1. Scans the game directory for base `.xci`/`.nsp` and update `.nsp` files.
  2. Uses `prod.keys` to decrypt and unpack NCAs.
  3. Extracts the application partition into `<id>_build/extract/v<version>/`:
     - `ExeFS/`: Original encrypted/compressed NSO modules (`main`, `sdk`, `subsdk*`, `rtld`, `main.npdm`).
     - `RomFS/`: Raw game data filesystem (textures, audio banks, levels, shaders, scripts).
     - `control.nacp`: Nintendo Application Control Property (title name, version, author, icon).
     - `icon.jpg`: Official 256x256 game icon.

---

### Stage 3: Code Module Rewriter (`patch_nso.py`)
The Switch CPU runs 64-bit ARMv8 (AArch64), but the Switch Horizon OS ABI differs significantly from Apple Silicon macOS/iOS:
1. **The `x18` Register:** Reserved by Apple OS kernels for internal thread state (`pthread_self` / platform data). Switch code freely uses `x18` as a general-purpose register. The rewriter scans and redirects all `x18` usage.
2. **Thread Local Storage (TLS):** Switch accesses `TPIDR_EL0` directly. The rewriter wraps TLS accesses with host trampolines.
3. **Supervisor Calls (`SVC`):** Horizon kernel calls (`SVC 0x1f`, `SVC 0x21`, etc.) are intercepted with branch fixups to HLE handlers.
4. **Relocations & Fixups:** Emits `*.patched.bin`, `*.fixups.tsv`, `*.gates.tsv`, `*.cuts.tsv`, and `*.obs.tsv`.

---

### Stage 4: Shader Splitting & Analysis
- **Tool:** `dm/gfx/tools/shader_split.py`
- **Action:**
  1. Locates compiled NVN shader binaries inside the extracted `RomFS` (e.g. `bin/archive/shader/`).
  2. Splits monolithic shader bundles into individual vertex, fragment, and compute shader stages.
  3. Computes unique 64-bit hashes for each shader.
  4. Cross-references hashes with the profile's `shader_map.tsv` and `pso_manifest.tsv`.

#### Unbounded Resource Guard (`c1_guard.py`)
Certain Nintendo engines (e.g., Pokémon, Mario) allocate constant buffers or samplers dynamically. `c1_guard.py` generates the `c1_full.tsv` table to prevent out-of-bounds GPU indexing:
```bash
python3 nxnative/dm/gfx/tools/c1_guard.py \
  <shader_cache_dir> \
  nxnative/dm/games/<TitleID>/c1_full.tsv
```

---

### Stage 5: Metal Shader Compilation
- **Tool:** `dm/gfx/tools/dmsh_build.py`
- **Translation Chain:**
  ```
  NVN Maxwell/Pascal GPU Bytecode
                 |  [dmsh_xlate_bin]
                 v
      SPIR-V Intermediate Representation
                 |  [spirv-cross]
                 v
        Metal Shading Language (MSL)
                 |  [xcrun metal & metallib]
                 v
     Compiled Metal Libraries (.metallib)
  ```
- **Output:** `<id>_build/shader/ios/b-<chain_id>/<shader_hash>_b.metallib`
- **Reusability:** Shaders are cached permanently based on input fingerprints (`.key`). Re-running skips all unchanged shaders.

---

### Stage 6: Application Compilation

#### Target A: Native macOS Runner (`dmhost`)
Compiled using Clang via `make`:
```bash
make -C nxnative/dm/host GAME=<TitleID> dmhost
```
Links:
- `front_mac.m` (Cocoa window, CAMetalLayer, keyboard/mouse event monitors).
- HLE subsystem (`hle_fs.c`, `hle_hid.c`, `hle_audio.c`, `hle_nvdrv.c`, etc.).
- Metal renderer (`nvn_mtl.m`, `nvn_dirty.c`, `nvn_deswizzle_gpu.m`).

#### Target B: iOS Application (`DmIOS.app`)
Compiled using `xcodebuild`:
- `gen_build.py` and `gen_embed.py` generate assembly thunks embedding the rewritten code modules.
- `xcodegen` generates `DmIOS.xcodeproj`.
- `xcodebuild` produces the compiled unsigned Mach-O bundle `Release-iphoneos/DmIOS.app`.

---

### Stage 7: IPA Packaging (`pack_ipa.py`)
- **Tool:** `nxnative/dm/ios/tools/pack_ipa.py`
- **Direct-to-Zip Architecture:** Packs the compiled `DmIOS.app`, the translated Metal shader libraries, and the multi-gigabyte `RomFS` filesystem directly into an IPA archive without intermediate temporary disk copies, preserving external SSD performance.
- **Output:** `<GameName>.ipa` (e.g., `PokMonLetsGoPikachu.ipa`, 3.9 GB).

---

## Survey & Profile Generation

When encountering a game without an existing profile in `nxnative/dm/games/`:
1. `build_ipa_from_nsp.py` automatically initiates a survey.
2. It parses SDK version strings (e.g. `nnSdk-5_4_151-Rele`), graphics API usage (`nvn` vs `vulkan`), audio middleware (`Wwise`, `opus`, `audren`), and saves a comprehensive report:
   ```
   <GameDir>/<TitleID>_survey/survey.md
   ```
3. It creates a provisional profile (`game.tsv`) detailing:
   - `modules`: `main subsdk0 subsdk1 sdk`
   - `romfs_marker`: Path to a known valid file in RomFS
   - `mem_reserve`, `mem_alias`, `mem_stack`, `app_pool`, `mem_used`
   - `nvn_tex_base`, `nvn_samp_base`, `nvn_img_base`
