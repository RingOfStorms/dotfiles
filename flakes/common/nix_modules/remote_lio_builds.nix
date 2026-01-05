{
  config,
  lib,
  ...
}:
let
  hasSecret =
    secret:
    let
      secrets = config.age.secrets or { };
    in
    secrets ? ${secret} && secrets.${secret} != null;
in
{
  nix = lib.mkIf (hasSecret "nix2lio") {
    distributedBuilds = true;
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
          "uid-range" # Often helpful
          "recursive-nix"
        ];
        mandatoryFeatures = [ ];
        sshKey = config.age.secrets.nix2lio.path;
      }
    ];
  };
}
