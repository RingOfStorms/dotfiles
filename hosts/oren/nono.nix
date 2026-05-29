{
  pkgs,
  inputs,
  ...
}:
let
  # nono requires rustc >= 1.95, which neither nixos-25.11 nor nixos-unstable
  # ships at the moment. Pull a pinned stable toolchain from rust-overlay and
  # build a dedicated rustPlatform so the rest of the system keeps using
  # nixpkgs' default rustc.
  rustPkgs = import inputs.nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    overlays = [ inputs.rust-overlay.overlays.default ];
    config.allowUnfree = true;
  };

  rustToolchain = rustPkgs.rust-bin.stable.latest.default;

  rustPlatform = rustPkgs.makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };

  nono = rustPlatform.buildRustPackage {
    pname = "nono";
    version = inputs.nono.shortRev or inputs.nono.dirtyShortRev or "unknown";

    src = inputs.nono;

    cargoLock.lockFile = "${inputs.nono}/Cargo.lock";

    nativeBuildInputs = with pkgs; [
      pkg-config
      cmake # needed by aws-lc-rs
    ];

    buildInputs = with pkgs; [
      dbus # needed by keyring (sync-secret-service)
      libsecret # needed by keyring (sync-secret-service)
    ];

    cargoBuildFlags = [
      "-p"
      "nono-cli"
    ];

    cargoTestFlags = [
      "-p"
      "nono-cli"
    ];

    # Some tests require sandbox capabilities not available in nix build
    doCheck = false;

    meta = {
      description = "Secure, kernel-enforced sandbox CLI for AI agents";
      homepage = "https://github.com/always-further/nono";
      license = pkgs.lib.licenses.asl20;
      mainProgram = "nono";
    };
  };
in
{
  environment.systemPackages = [ nono ];
}
