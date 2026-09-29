{ pkgs, inputs, ... }:
let
  # Keep Nono pinned independently; its CLI needs a newer Rust toolchain.
  rustPkgs = import inputs.nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    overlays = [ inputs.rust-overlay.overlays.default ];
  };
  rustToolchain = rustPkgs.rust-bin.stable.latest.default;
  nono = (rustPkgs.makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  }).buildRustPackage {
    pname = "nono";
    src = inputs.nono;
    version = inputs.nono.shortRev;
    cargoLock.lockFile = "${inputs.nono}/Cargo.lock";

    nativeBuildInputs = [
      rustPkgs.pkg-config
      rustPkgs.cmake # aws-lc-rs
    ];
    buildInputs = [
      rustPkgs.dbus # keyring (sync-secret-service)
      rustPkgs.libsecret
    ];

    cargoBuildFlags = [ "-p" "nono-cli" ];
    cargoTestFlags = [ "-p" "nono-cli" ];
    # Some tests need sandbox capabilities the Nix build sandbox lacks.
    doCheck = false;

    meta = {
      description = "Secure, kernel-enforced sandbox CLI for AI agents";
      homepage = "https://github.com/always-further/nono";
      license = rustPkgs.lib.licenses.asl20;
      mainProgram = "nono";
    };
  };
in
{
  environment.systemPackages = [ nono ];
}
