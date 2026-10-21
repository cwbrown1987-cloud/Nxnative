# Chapter 1: Prerequisites & Toolchain Setup

This chapter details the prerequisite software, system libraries, development toolchains, and environment configurations required to build native Apple Silicon ports of Nintendo Switch games.

---

## 1. Metal Toolchain Installation

Modern versions of Xcode (Xcode 15 / 16) decouple the standalone Metal shader compiler from the standard Command Line Tools. Without the Metal Toolchain component, running `xcrun -sdk macosx metal` or `xcrun -sdk iphoneos metallib` fails with:

```text
xcrun: error: unable to find utility "metal", not a developer tool or in PATH
```

### Verification Command
```bash
xcrun -sdk macosx metal -v
```

### Installation
If missing, download and install the official Apple Metal Toolchain component directly via `xcodebuild`:

```bash
xcodebuild -downloadComponent MetalToolchain
```
*Note: This downloads approximately 840 MB and installs directly into Xcode's developer toolchain directory.*

---

## 2. Homebrew Dependencies

The following native CLI tools are mandatory:

```bash
brew install dotnet-sdk xcodegen spirv-cross
```

| Tool | Minimum Version | Purpose |
| :--- | :--- | :--- |
| **`dotnet`** | 9.0+ / 10.0+ | Executes `nx_extract` for decrypting and unpacking Switch `.xci` / `.nsp` archives. |
| **`xcodegen`** | 2.40+ | Generates the `DmIOS.xcodeproj` project dynamically from `project.yml`. |
| **`spirv-cross`** | 1.4+ | Translates SPIR-V intermediate shader bytecode into Metal Shading Language (MSL). |

### .NET SDK Configuration
On Apple Silicon macOS, Homebrew installs `dotnet` into `/opt/homebrew/opt/dotnet/libexec`. macOS shells and subprocesses must have `DOTNET_ROOT` explicitly defined, otherwise .NET host resolution will fail:

```bash
export DOTNET_ROOT="/opt/homebrew/opt/dotnet/libexec"
export PATH="$DOTNET_ROOT:$PATH"
```

To persist this across sessions, add it to your shell configuration (`~/.zshrc`):
```bash
echo 'export DOTNET_ROOT="/opt/homebrew/opt/dotnet/libexec"' >> ~/.zshrc
echo 'export PATH="$DOTNET_ROOT:$PATH"' >> ~/.zshrc
```

---

## 3. Python Environment & Packages

Python 3.10+ is required along with specialized binary manipulation and decompression packages:

```bash
pip3 install lz4 capstone fonttools
```

### Purpose of Python Packages:
- **`lz4`:** Decompresses Nintendo Switch NSO binary segments (`.text`, `.rodata`, `.data`) and RomFS assets.
- **`capstone`:** Disassembles AArch64 machine instructions for static call-site inspection, PLT resolution, and register analysis.
- **`fonttools`:** Generates Nintendo extension character fonts (`make_ext_font.py`) to render Joy-Con and system glyphs.

---

## 4. Encryption Keys (`prod.keys`)

Switch game dumps (`.xci`, `.nsp`, `.nca`) are hardware-encrypted. `nx_extract` requires valid Nintendo Switch production keys (`prod.keys`) containing:
- Master keys (`master_key_00` through latest)
- Header keys (`header_key`)
- Package 1 & 2 keys
- Title key decryption keys

### Safe Storage Rules:
1. Always store `prod.keys` in a secure, non-repository path (e.g. `/Volumes/RAGHAV SSD/nintendo/keys/prod.keys`).
2. **NEVER** commit `prod.keys` to Git repositories or print key hex strings into console output or logs.
3. Validate keys before running extraction:
   ```bash
   dotnet nxnative/dm/tools/nx_extract/nx_extract.dll --keys /path/to/prod.keys --verify
   ```

---

## 5. Summary Verification Script

Run this verification script to ensure your environment is 100% prepared:

```bash
#!/usr/bin/env bash
set -e

echo "=== Checking Apple Silicon & macOS Toolchain ==="
uname -m | grep -q "arm64" && echo "✓ Architecture: Apple Silicon (arm64)" || (echo "✗ Error: Apple Silicon required" && exit 1)
which clang > /dev/null && echo "✓ Clang: $(clang --version | head -1)"
xcrun -sdk macosx metal -v > /dev/null 2>&1 && echo "✓ Metal Toolchain: Present" || echo "✗ Warning: Metal Toolchain missing (run: xcodebuild -downloadComponent MetalToolchain)"
which dotnet > /dev/null && echo "✓ .NET SDK: $(dotnet --version)"
which xcodegen > /dev/null && echo "✓ xcodegen: $(xcodegen --version)"
which spirv-cross > /dev/null && echo "✓ spirv-cross: Present"
python3 -c "import lz4, capstone, fontTools; print('✓ Python modules: lz4, capstone, fonttools OK')"
echo "==============================================="
```
