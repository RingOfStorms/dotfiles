{
  lib,
  rustPlatform,
  pkg-config,
  cmake,
  dbus,
  libsecret,
  src,
  version,
}:
rustPlatform.buildRustPackage {
  pname = "nono";
  inherit src version;
  cargoLock.lockFile = "${src}/Cargo.lock";

  nativeBuildInputs = [
    pkg-config
    cmake # aws-lc-rs
  ];
  buildInputs = [
    dbus # keyring (sync-secret-service)
    libsecret
  ];

  cargoBuildFlags = [ "-p" "nono-cli" ];
  cargoTestFlags = [ "-p" "nono-cli" ];
  # Some tests need sandbox capabilities the Nix build sandbox lacks.
  doCheck = false;

  meta = {
    description = "Secure, kernel-enforced sandbox CLI for AI agents";
    homepage = "https://github.com/always-further/nono";
    license = lib.licenses.asl20;
    mainProgram = "nono";
  };
}
