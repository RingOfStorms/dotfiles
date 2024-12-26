{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Secrets management for nix
    ragenix = {
      url = "github:yaxitech/ragenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { ragenix, ... }:
    {
      nixosModules = {
        default =
          { config, lib, ... }:
          let
            cfg = config.mods.common;
          in
          with lib;
          {
            options.mods.common = {
              systemName = mkOption {
                type = types.str;
                description = "The name of the system.";
              };
              allowUnfree = mkOption {
                type = types.bool;
                default = false;
                description = "Allow unfree software.";
              };
              primaryUser = mkOption {
                type = types.str;
                # default = "josh";
                description = "The primary user of the system.";
              };
              defaultLocal = mkOption {
                type = types.str;
                default = "en_US.UTF-8";
                description = "The default locale.";
              };
              sshPortOpen = mkOption {
                type = types.bool;
                default = true;
                description = "Open the ssh port.";
              };
              # users = mkOption {
            };

            imports = [
              # Secrets management
              ragenix.nixosModules.age
              # NOTE: Ragenix requires services.openssh.enable to be true otherwise it would require manually setting public keys, so ssh is enabled in the common module as well
              ./ssh.nix
              ./ragenix.nix
            ];
            config = {
              _module.args = {
                inherit ragenix;
              };
              # Enable flakes
              nix.settings.experimental-features = [
                "nix-command"
                "flakes"
              ];

              # name this computer
              networking = {
                hostName = cfg.systemName;
              };

              # allow mounting ntfs filesystems
              boot.supportedFilesystems = [ "ntfs" ];

              nix.settings = {
                max-jobs = "auto";
                # Fallback quickly if substituters are not available.
                connect-timeout = 5;
                download-attempts = 3;
                # The default at 10 is rarely enough.
                log-lines = 50;
                # Avoid disk full issues
                max-free = (3000 * 1024 * 1024);
                min-free = (1000 * 1024 * 1024);
                # Avoid copying unnecessary stuff over SSH
                builders-use-substitutes = true;
                # Slower but more robust during crash TODO enable once we upgrade nix
                # fsync-store-paths = true;
                # fsync-metadata = true;
                auto-optimise-store = true;

                # TODO should I have this set for my user...
                trusted-users = [
                  "root"
                  cfg.primaryUser
                ];
              };

              # rate limiting for github
              nix.extraOptions = ''
                keep-outputs = true
                keep-derivations = true
                !include ${config.age.secrets.github_read_token.path}
              '';

              # nix helper
              programs.nh = {
                enable = true;
                clean.enable = true;
                clean.extraArgs = "--keep 10";
                # TODO this may need to be defined higher up if it is ever different for a machine...
                flake = "/home/${cfg.primaryUser}/.config/nixos-config/hosts/${cfg.systemName}";
              };

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
                    ];
                    mandatoryFeatures = [ ];
                  }
                ];
              };

              # TODO do I want this dynamic at all? Roaming?
              time.timeZone = "America/Chicago";
              # Select internationalization properties.
              i18n.defaultLocale = cfg.defaultLocal;
              i18n.extraLocaleSettings = {
                LC_ADDRESS = cfg.defaultLocal;
                LC_IDENTIFICATION = cfg.defaultLocal;
                LC_MEASUREMENT = cfg.defaultLocal;
                LC_MONETARY = cfg.defaultLocal;
                LC_NAME = cfg.defaultLocal;
                LC_NUMERIC = cfg.defaultLocal;
                LC_PAPER = cfg.defaultLocal;
                LC_TELEPHONE = cfg.defaultLocal;
                LC_TIME = cfg.defaultLocal;
              };

              # make shutdown faster for waiting
              systemd.extraConfig = ''
                DefaultTimeoutStopSec=5s
              '';

              # Some basics
              nixpkgs.config.allowUnfree = settings.allowUnfree;
              nixpkgs.config.allowUnfreePredicate = (pkg: true);
            };
          };
      };
    };
}
