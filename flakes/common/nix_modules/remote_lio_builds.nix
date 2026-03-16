{
  config,
  lib,
  ...
}:
let
  baoSecrets = config.ringofstorms.secretsBao.secrets or { };
  hasNix2Nix = baoSecrets ? "nix2nix_2026-03-15";
  secretPath = if hasNix2Nix then baoSecrets."nix2nix_2026-03-15".path else "";
in
{
  nix = lib.mkIf hasNix2Nix {
    distributedBuilds = true;

    settings = {
      substituters = lib.mkAfter [ "http://lio:5000" ];
      trusted-public-keys = lib.mkAfter [ "lio:9jKQ2xJyZjD0AWFzMcLe5dg3s8vOJ3uffujbUkBg4ms=" ];
    };

    buildMachines = [
      {
        hostName = "lio";
        system = "x86_64-linux";
        protocol = "ssh-ng";
        maxJobs = 32;
        speedFactor = 2;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
          "uid-range"
          "recursive-nix"
        ];
        mandatoryFeatures = [ ];
        sshKey = secretPath;
      }
    ];
  };
}
