{
  config,
  lib,
  ...
}:
let
  keyName = "remote_lio_builds_2026-10-22";
  # sec-agent (current); secretsBao is legacy and kept only as a fallback.
  secSecrets = config.ringofstorms.secrets.agent.secrets or { };
  baoSecrets = config.ringofstorms.secretsBao.secrets or { };
  hasNix2Nix = secSecrets ? ${keyName} || baoSecrets ? ${keyName};
  secretPath = "/var/lib/secrets_manager_hydrated/${keyName}";
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
        sshUser = "nix-builder";
        sshKey = secretPath;
      }
    ];
  };
}
