# Building on x86_64 macOS (Intel Macs & AMD Hackintosh)

[English](#english) | [中文](#中文)

---

## English

Originally, `nxnative` assumed an Apple Silicon (arm64) host environment:
1. `dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate` was distributed as an arm64-only Mach-O binary, which caused `Exec format error` on x86_64 macOS.
2. Toolchain paths assumed Homebrew on Apple Silicon (`/opt/homebrew`).
3. Build scripts required specific environment variables and assumptions.

### What This Branch Adds
- **Universal `dmsh_xlate` Launcher**: Automatically detects the host architecture (`uname -m`). On `arm64`, it executes the native binary (`dmsh_xlate.arm64`). On `x86_64`, it transparently runs `dotnet exec dmsh_xlate.dll` using the host's .NET 10 runtime.
- **Dynamic Toolchain Detection**: Automatically detects `DOTNET_ROOT`, `DOTNET_ROOT_X64`, and common Homebrew paths across both `/usr/local` (Intel) and `/opt/homebrew` (Apple Silicon).
- **Toolchain Fingerprint Updates**: Full support for running `dmsh_chain.py --update-lock` and `--header` with locally compiled `spirv-cross` and Apple Metal toolchains.

### Prerequisites for x86_64 macOS
1. **.NET SDK 10**:
   ```bash
   brew install dotnet
   # Or download the x64 macOS tarball and export DOTNET_ROOT
   export DOTNET_ROOT="/path/to/dotnet"
   ```
2. **Apple Metal Toolchain**:
   If `xcrun -sdk macosx metal --version` is missing on your x86_64 macOS installation, download the official Apple Metal Toolchain:
   ```bash
   xcodebuild -downloadComponent MetalToolchain
   ```
3. **Build Dependencies**:
   ```bash
   brew install xcodegen zstd spirv-cross
   pip3 install lz4 capstone fonttools
   ```

### Tested Hardware
- **CPU**: AMD Ryzen 5 2600 (6 Cores / 12 Threads, x86_64)
- **OS**: macOS Darwin 25.6.0 (Hackintosh)
- **Target Device**: iPhone 15 (iOS, 6GB RAM)
- **Game Tested**: *Super Mario 3D World + Bowser's Fury* (v1.2.2) — Successfully built 3.0GB `.ipa` with 11,079 ahead-of-time compiled Metal shaders. 60 FPS verified.

---

## 中文

原版 `nxnative` 默认假定运行在 Apple Silicon (arm64) 架构的 Mac 上：
1. 内置的 `dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate` 为纯 arm64 架构 Mach-O 二进制，在 x86_64 (Intel Mac 或 AMD 黑苹果) 上直接报错 `Exec format error`；
2. 工具链路径默认绑定 Apple Silicon 的 `/opt/homebrew`；
3. 构建过程对 .NET 运行时及工具签名有架构敏感约束。

### 本分支特性
- **双架构自适应启动器**：重构 `dmsh_xlate` 为通用脚本。在 Apple Silicon (arm64) 环境下原生直接执行 `dmsh_xlate.arm64`；在 x86_64 环境下自动回退为调用系统的 `dotnet exec dmsh_xlate.dll`，兼顾性能与跨架构兼容性。
- **动态工具链探测**：在 `scripts/build_ipa_from_nsp.py` 中自动识别 `DOTNET_ROOT`、系统架构及 `/usr/local` / `/opt/homebrew` 路径。
- **完整跨平台验证**：修复在缺少 USER 环境变量时的 xcodegen 构建异常，规范化 `dmsh_chain` 锁文件管理。

### x86_64 macOS 前置环境
1. **.NET SDK 10**：
   ```bash
   brew install dotnet
   # 或解压官方 x64 macOS 安装包并配置环境变量
   export DOTNET_ROOT="/path/to/dotnet"
   ```
2. **Apple Metal 工具链**：
   若系统提示缺少 metal 编译器，执行官方组件拉取：
   ```bash
   xcodebuild -downloadComponent MetalToolchain
   ```
3. **必要编译工具**：
   ```bash
   brew install xcodegen zstd spirv-cross
   pip3 install lz4 capstone fonttools
   ```

### 实机验证配置
- **主机硬件**：AMD Ryzen 5 2600 (6 核 12 线程 x86_64 黑苹果)
- **目标设备**：iPhone 15 (6GB RAM)
- **实测成果**：《超级马力欧 3D 世界 + 狂怒世界》(v1.2.2)，编译 11,079 个 Metal Shader，成功打包出 3.0GB 独立 `.ipa`，实机 60 帧满帧流畅运行，手柄即插即玩。
