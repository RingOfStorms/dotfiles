{
  pkgs,
  ...
}:
let
  nono = pkgs.rustPlatform.buildRustPackage rec {
    pname = "nono";
    version = "0.17.0";

    src = pkgs.fetchFromGitHub {
      owner = "always-further";
      repo = "nono";
      rev = "v${version}";
      hash = "sha256-LEUblw0AJoqyND086eVzs7piupsbU3kcjL7Flt5mkeg=";
    };

    cargoLock.lockFile = "${src}/Cargo.lock";

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
