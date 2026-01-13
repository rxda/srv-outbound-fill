{
  description = "Rust Stable: Musl + Windows (Standard GCC Linker)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, fenix, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # 1. 定义 Rust 工具链 (Host + Musl Target + Windows Target)
        rustToolchain = fenix.packages.${system}.combine [
          fenix.packages.${system}.stable.toolchain
          fenix.packages.${system}.targets.x86_64-unknown-linux-musl.stable.rust-std
          fenix.packages.${system}.targets.x86_64-pc-windows-gnu.stable.rust-std
        ];

        # 2. 获取标准的 GCC 交叉编译工具链
        # muslCc: 提供 musl-gcc
        muslCc = pkgs.pkgsStatic.stdenv.cc;
        # mingwCc: 提供 x86_64-w64-mingw32-gcc
        mingwCc = pkgs.pkgsCross.mingwW64.stdenv.cc;

      in
      {
        devShells.default = pkgs.mkShell {
          name = "rust-std-env";

          # 3. 安装包
          packages = [
            rustToolchain
            pkgs.pkg-config # 处理 C 库依赖
            pkgs.sccache
            # 将交叉编译器放入 PATH，方便 build.rs 或是 cargo 自动发现
            muslCc
            mingwCc
          ];

          # 4. 环境变量配置 (这是核心)
          RUSTC_WRAPPER = "${pkgs.sccache}/bin/sccache";

          # 告诉 Cargo：当目标是 musl/windows 时，使用哪个 Linker 和 C Compiler。
          # 这里我们不传任何额外的 RUSTFLAGS，完全使用 GCC 默认行为。

          # --- Target: x86_64-unknown-linux-musl ---
          # C 编译器 (用于 C 依赖)
          CC_x86_64_unknown_linux_musl = "${muslCc}/bin/${muslCc.targetPrefix}cc";
          CXX_x86_64_unknown_linux_musl = "${muslCc}/bin/${muslCc.targetPrefix}c++";
          # Linker (用于最终链接)
          CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER = "${muslCc}/bin/${muslCc.targetPrefix}cc";

          # --- Target: x86_64-pc-windows-gnu ---
          # C 编译器
          CC_x86_64_pc_windows_gnu = "${mingwCc}/bin/${mingwCc.targetPrefix}cc";
          CXX_x86_64_pc_windows_gnu = "${mingwCc}/bin/${mingwCc.targetPrefix}c++";
          # Linker
          CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = "${mingwCc}/bin/${mingwCc.targetPrefix}cc";

          shellHook = ''
            echo "🔗 Rust Env with Shared Symlink"
            
            # --- 配置: 共享 Target 目录 ---
            # 定义真实的物理存储路径
            REAL_TARGET_DIR="$HOME/.cargo/target_cache"
            mkdir -p "$REAL_TARGET_DIR"

            # 告诉 Cargo 使用这个绝对路径
            export CARGO_TARGET_DIR="$REAL_TARGET_DIR"

            # --- 核心逻辑: 创建软链接 ---
            # 只有当当前目录下有 Cargo.toml 时才创建（避免在非项目根目录乱建）
            if [ -f "Cargo.toml" ]; then
                # ln -snf: 
                #   -s: 软链接
                #   -n: 如果目标是目录，视为文件处理（为了正确替换旧链接）
                #   -f: 强制覆盖
                ln -snf "$REAL_TARGET_DIR" target
                echo "   ✅ Symlinked ./target -> $REAL_TARGET_DIR"
            fi

            # --- Sccache 配置 ---
            export SCCACHE_DIR="$HOME/.cache/sccache"
            
            echo "   ⚡ Sccache running"
            echo ""
            echo "Run: cargo build --target x86_64-unknown-linux-musl"
          '';
        };
      }
    );
}