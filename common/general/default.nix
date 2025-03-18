{
  config,
  lib,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "general"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
  top_cfg = config.${ccfg.custom_config_key};
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      flakeOptions = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable nix flake options";
      };
      unfree = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable unfree packages";
      };
      readWindowsDrives = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Read windows drives";
      };
      disableRemoteBuildsOnLio = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Disable remote builds on lio";
      };
      timezone = lib.mkOption {
        type = lib.types.str;
        default = "America/Chicago";
        description = "Timezone";
      };
      defaultLocal = lib.mkOption {
        type = lib.types.str;
        default = "en_US.UTF-8";
        description = "Default locale";
      };
      fastShutdown = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Fast shutdown";
      };
      enableSleep = lib.mkEnableOption (lib.mdDoc "Enable auto sleeping");
    };
  imports = [
    ./shell/common.nix
    ./fonts.nix
    ./tty_caps_esc.nix
  ];
  config = {
    # name this computer
    networking = {
      hostName = top_cfg.systemName;
      nftables.enable = true;
      firewall.enable = true;
    };

    # Enable flakes
    nix.settings.experimental-features = lib.mkIf cfg.flakeOptions [
      "nix-command"
      "flakes"
    ];

    # Allow unfree
    nixpkgs.config.allowUnfree = cfg.unfree;
    nixpkgs.config.allowUnfreePredicate = (pkg: cfg.unfree);
    environment.variables = lib.mkIf cfg.unfree {
      NIXPKGS_ALLOW_UNFREE = "1";
    };

    # allow mounting ntfs filesystems
    boot.supportedFilesystems = lib.mkIf cfg.readWindowsDrives [ "ntfs" ];

    # make shutdown faster for waiting
    systemd.extraConfig = lib.mkIf cfg.fastShutdown ''
      DefaultTimeoutStopSec=8s
    '';

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
      auto-optimise-store = true;
      trusted-users = [
        "root"
        "@wheel"
      ];
      substituters = [
        "https://hyprland.cachix.org"
        "https://cosmic.cachix.org/"
      ];
      trusted-public-keys = [
        "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
        "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE="
      ];
    };
    nix.extraOptions = ''
      keep-outputs = true
      keep-derivations = true
      ${lib.optionalString (
        # TODO revisit this should it move?
        config ? age && config.age ? secrets && config.age.secrets ? github_read_token
      ) "!include ${config.age.secrets.github_read_token.path}"}
    '';

    # Enable zsh
    programs.zsh.enable = true;
    environment.pathsToLink = [ "/share/zsh" ];

    # nix helper
    programs.nh = {
      enable = true;
      clean.enable = true;
      clean.extraArgs = "--keep 10";
      # `flake` path is set in users/default.nix for the primary user if set
    };

    # Remote build off home lio computer
    programs.ssh.extraConfig = lib.mkIf (!cfg.disableRemoteBuildsOnLio) ''
      Host lio_
        PubkeyAcceptedKeyTypes ssh-ed25519
        ServerAliveInterval 60
        IPQoS throughput
        ${lib.optionalString (
          config ? age && config.age ? secrets && config.age.secrets ? nix2lio
        ) "IdentityFile ${config.age.secrets.nix2lio.path}"}
    '';
    nix = {
      distributedBuilds = lib.mkIf (!cfg.disableRemoteBuildsOnLio) true;
      buildMachines = lib.mkIf (!cfg.disableRemoteBuildsOnLio) [
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

    # TODO can I make this Roaming automatically somehow?
    time.timeZone = cfg.timezone;
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

    # Turn off sleep
    systemd.sleep.extraConfig = lib.mkIf (!cfg.enableSleep) ''
      [Sleep]
      AllowSuspend=no
      AllowHibernation=no
      AllowSuspendThenHibernate=no
      AllowHybridSleep=no
    '';
  };
}
