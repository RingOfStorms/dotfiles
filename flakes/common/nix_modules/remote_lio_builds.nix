{
  config,
  ...
}:
{
  # Remote build off home lio computer
  programs.ssh.extraConfig = ''
    Host lio_
      PubkeyAcceptedKeyTypes ssh-ed25519
      ServerAliveInterval 60
      IPQoS throughput
      IdentityFile ${config.age.secrets.nix2lio.path}
  '';
  nix = {
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
