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
  # Remote build off home lio computer
  programs.ssh.extraConfig = lib.mkIf (hasSecret "nix2lio") ''
    Host lio_
      PubkeyAcceptedKeyTypes ssh-ed25519
      ServerAliveInterval 60
      IPQoS throughput
      IdentityFile ${config.age.secrets.nix2lio.path}
  '';
  nix = lib.mkIf (hasSecret "nix2lio") {
    distributedBuilds = true;
    buildMachines = [
      {
        # TODO require hostname in ssh config?
        hostName = "lio_";
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
        ];
        mandatoryFeatures = [ ];
      }
    ];
  };
}
