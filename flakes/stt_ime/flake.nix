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

        # Rust STT streaming CLI
        stt-stream = craneLib.buildPackage {
          pname = "stt-stream";
          version = "0.1.0";
          src = craneLib.cleanCargoSource ./stt-stream;

          nativeBuildInputs = with pkgs; [
            pkg-config
            cmake # for whisper-rs
            clang
            llvmPackages.libclang
          ];

          buildInputs = with pkgs; [
            alsa-lib
            openssl
            # whisper.cpp dependencies
            openblas
          ];

          # For bindgen to find libclang
          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";

          # Enable CUDA if available (user can override)
          WHISPER_CUBLAS = "OFF";
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
      in
      {
        packages = {
          inherit stt-stream fcitx5-stt;
          default = fcitx5-stt;
        };

        # Expose as runnable apps
        apps = {
          stt-stream = {
            type = "app";
            program = "${stt-stream}/bin/stt-stream";
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
        in
        {
          options.ringofstorms.sttIme = {
            enable = lib.mkEnableOption "Speech-to-text input method for Fcitx5";

            model = lib.mkOption {
              type = lib.types.str;
              default = "base.en";
              description = "Whisper model to use (tiny, base, small, medium, large)";
            };

            useGpu = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to use GPU acceleration (CUDA)";
            };
          };

          config = lib.mkIf cfg.enable {
            # Ensure fcitx5 addon is available
            i18n.inputMethod.fcitx5.addons = [ sttPkgs.fcitx5-stt ];

            # Add STT to the Fcitx5 input method group
            # This assumes de_plasma sets up Groups/0 with keyboard-us (0) and mozc (1)
            i18n.inputMethod.fcitx5.settings.inputMethod = {
              "Groups/0/Items/2".Name = "stt";
            };

            # Make stt-stream available system-wide
            environment.systemPackages = [ sttPkgs.stt-stream ];

            # Set default model via environment
            environment.sessionVariables = {
              STT_STREAM_MODEL = cfg.model;
              STT_STREAM_USE_GPU = if cfg.useGpu then "1" else "0";
            };
          };
        };
    };
}
