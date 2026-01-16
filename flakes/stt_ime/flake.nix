{
  description = "Local speech-to-text input method for Fcitx5";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    crane.url = "github:ipetkov/crane";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      crane,
      flake-utils,
      ...
    }:
    let
      # Systems we support
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    flake-utils.lib.eachSystem supportedSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        craneLib = crane.mkLib pkgs;

        # Common build inputs for stt-stream
        commonNativeBuildInputs = with pkgs; [
          pkg-config
          cmake
          git # required by whisper-rs-sys build
        ];

        commonBuildInputs = with pkgs; [
          alsa-lib
          openssl
        ];

        # CPU-only build (default)
        stt-stream = craneLib.buildPackage {
          pname = "stt-stream";
          version = "0.1.0";
          src = craneLib.cleanCargoSource ./stt-stream;

          nativeBuildInputs = commonNativeBuildInputs ++ (with pkgs; [
            clang
            llvmPackages.libclang
          ]);

          buildInputs = commonBuildInputs ++ (with pkgs; [
            openblas
          ]);

          # For bindgen to find libclang
          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
        };

        # GPU build with ROCm/HIP support (AMD GPUs)
        stt-stream-hip = craneLib.buildPackage {
          pname = "stt-stream-hip";
          version = "0.1.0";
          src = craneLib.cleanCargoSource ./stt-stream;

          nativeBuildInputs = commonNativeBuildInputs ++ (with pkgs; [
            # ROCm toolchain - clr contains the properly wrapped hipcc
            rocmPackages.clr
            # rocminfo provides rocm_agent_enumerator which hipcc needs
            rocmPackages.rocminfo
          ]);

          buildInputs = commonBuildInputs ++ (with pkgs; [
            # ROCm/HIP libraries needed at link time
            rocmPackages.clr # HIP runtime
            rocmPackages.hipblas
            rocmPackages.rocblas
            rocmPackages.rocm-runtime
            rocmPackages.rocm-device-libs
            rocmPackages.rocm-comgr
          ]);

          # Enable hipblas feature
          cargoExtraArgs = "--features hipblas";

          # The clr package's hipcc is already wrapped with all the right paths,
          # but we need LIBCLANG_PATH for bindgen
          LIBCLANG_PATH = "${pkgs.rocmPackages.llvm.clang}/lib";

          # Target common AMD GPU architectures (user can override via AMDGPU_TARGETS)
          # gfx1030 = RX 6000 series, gfx1100 = RX 7000 series, gfx906/gfx908 = MI50/MI100
          AMDGPU_TARGETS = "gfx1030;gfx1100";
        };

        # Fcitx5 C++ shim addon
        fcitx5-stt = pkgs.stdenv.mkDerivation {
          pname = "fcitx5-stt";
          version = "0.1.0";
          src = ./fcitx5-stt;

          nativeBuildInputs = with pkgs; [
            cmake
            extra-cmake-modules
            pkg-config
          ];

          buildInputs = with pkgs; [
            fcitx5
          ];

          cmakeFlags = [
            "-DSTT_STREAM_PATH=${stt-stream}/bin/stt-stream"
          ];

          # Install to fcitx5 addon paths
          postInstall = ''
            mkdir -p $out/share/fcitx5/addon
            mkdir -p $out/share/fcitx5/inputmethod
            mkdir -p $out/lib/fcitx5
          '';
        };
        # Fcitx5 addon variant using HIP-accelerated stt-stream
        fcitx5-stt-hip = pkgs.stdenv.mkDerivation {
          pname = "fcitx5-stt-hip";
          version = "0.1.0";
          src = ./fcitx5-stt;

          nativeBuildInputs = with pkgs; [
            cmake
            extra-cmake-modules
            pkg-config
          ];

          buildInputs = with pkgs; [
            fcitx5
          ];

          cmakeFlags = [
            "-DSTT_STREAM_PATH=${stt-stream-hip}/bin/stt-stream"
          ];

          postInstall = ''
            mkdir -p $out/share/fcitx5/addon
            mkdir -p $out/share/fcitx5/inputmethod
            mkdir -p $out/lib/fcitx5
          '';
        };
      in
      {
        packages = {
          inherit stt-stream stt-stream-hip fcitx5-stt fcitx5-stt-hip;
          default = fcitx5-stt;
        };

        # Expose as runnable apps
        apps = {
          stt-stream = {
            type = "app";
            program = "${stt-stream}/bin/stt-stream";
          };
          stt-stream-hip = {
            type = "app";
            program = "${stt-stream-hip}/bin/stt-stream";
          };
          default = {
            type = "app";
            program = "${stt-stream}/bin/stt-stream";
          };
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ stt-stream ];
          packages = with pkgs; [
            rust-analyzer
            rustfmt
            clippy
            fcitx5
          ];
        };

        # Dev shell with ROCm/HIP for GPU development
        devShells.hip = pkgs.mkShell {
          inputsFrom = [ stt-stream-hip ];
          packages = with pkgs; [
            rust-analyzer
            rustfmt
            clippy
            fcitx5
            rocmPackages.rocminfo # For debugging GPU detection
          ];
        };
      }
    )
    // {
      # NixOS module for integration
      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.ringofstorms.sttIme;
          sttPkgs = self.packages.${pkgs.stdenv.hostPlatform.system};

          # Select the appropriate package variant based on GPU backend
          sttStreamPkg =
            if cfg.gpuBackend == "hip" then sttPkgs.stt-stream-hip
            else sttPkgs.stt-stream;

          fcitx5SttPkg =
            if cfg.gpuBackend == "hip" then sttPkgs.fcitx5-stt-hip
            else sttPkgs.fcitx5-stt;
        in
        {
          options.ringofstorms.sttIme = {
            enable = lib.mkEnableOption "Speech-to-text input method for Fcitx5";

            model = lib.mkOption {
              type = lib.types.str;
              default = "base.en";
              description = "Whisper model to use (tiny, base, small, medium, large)";
            };

            gpuBackend = lib.mkOption {
              type = lib.types.enum [ "cpu" "hip" ];
              default = "cpu";
              description = ''
                GPU backend to use for acceleration:
                - cpu: CPU-only (default, works everywhere)
                - hip: AMD ROCm/HIP (requires AMD GPU with ROCm support)
              '';
            };

            useGpu = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to request GPU acceleration at runtime (--gpu flag)";
            };
          };

          config = lib.mkIf cfg.enable {
            # Ensure fcitx5 addon is available
            i18n.inputMethod.fcitx5.addons = [ fcitx5SttPkg ];

            # Add STT to the Fcitx5 input method group
            # This assumes de_plasma sets up Groups/0 with keyboard-us (0) and mozc (1)
            i18n.inputMethod.fcitx5.settings.inputMethod = {
              "Groups/0/Items/2".Name = "stt";
            };

            # Make stt-stream available system-wide
            environment.systemPackages = [ sttStreamPkg ];

            # Set default model via environment
            environment.sessionVariables = {
              STT_STREAM_MODEL = cfg.model;
              STT_STREAM_GPU = if cfg.useGpu then "1" else "0";
            };
          };
        };
    };
}
