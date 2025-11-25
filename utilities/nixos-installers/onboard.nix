{
  pkgs,
  config,
  lib,
  ...
}:
{
  options.onboardOpts = {
    hostName = lib.mkOption {
      type = lib.types.str;
      description = "Name of this machine/host";
    };
    primaryUser = lib.mkOption {
      type = lib.types.str;
      description = "Name of the user for this machine";
      default = "luser";
    };
  };
  config = {
    networking.hostName = config.onboardOpts.hostName;
    networking.networkmanager.enable = true;

    services.openssh.enable = true;
    networking.firewall.allowedTCPPorts = [ 22 ];

    # Nix options
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    environment.systemPackages = with pkgs; [
      vim
      curl
      git
      sudo
      fastfetch
    ];

    # Auto timezone
    time.timeZone = null;
    services.automatic-timezoned.enable = true;

    users.users."${config.onboardOpts.primaryUser}" = {
      initialHashedPassword = "$y$j9T$b8Fva/LoKIDdG/G2oHYG3.$D49NQrr5lJQnA5Bq2Wx9wEW1mU53W5Hvudw1K984gu6";
      isNormalUser = true;
      extraGroups = [
        "wheel"
        "networkmanager"
        "video"
        "input"
      ];
    };

    # Ensure SSH key pair generation for non-root users
    systemd.services.generate_ssh_key = {
      description = "Generate SSH key pair for ${config.onboardOpts.primaryUser}";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = "${config.onboardOpts.primaryUser}";
        Type = "oneshot";
      };
      script = ''
        #!/run/current-system/sw/bin/bash
        if [ ! -f /home/${config.onboardOpts.primaryUser}/.ssh/id_ed25519 ]; then
          if [ -v DRY_RUN ]; then
            echo "DRY_RUN is set. Would generate SSH key for ${config.onboardOpts.primaryUser}."
          else
            echo "Generating SSH key for ${config.onboardOpts.primaryUser}."
            mkdir -p /home/${config.onboardOpts.primaryUser}/.ssh
            chmod 700 /home/${config.onboardOpts.primaryUser}/.ssh
            /run/current-system/sw/bin/ssh-keygen -t ed25519 -f /home/${config.onboardOpts.primaryUser}/.ssh/id_ed25519 -N ""
          fi
        else
          echo "SSH key already exists for ${config.onboardOpts.primaryUser}."
        fi
      '';
    };
  };
}
