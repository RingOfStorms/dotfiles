{
  config,
  lib,
  pkgs,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "programs"
    "ssh"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
  users_cfg = config.${ccfg.custom_config_key}.users;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "ssh";
      sshPortOpen = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Open the ssh port.";
      };
      fail2Ban = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable fail2ban.";
      };
      allowRootPasswordLogin = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Allow root password login.";
      };
    };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      openssh
      autossh
    ];

    # Use fail2ban
    services.fail2ban = lib.mkIf cfg.fail2Ban {
      enable = true;
    };

    # Open ports in the firewall if enabled.
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.sshPortOpen [
      22 # sshd
    ];

    # Enable the OpenSSH daemon.
    services.openssh = {
      enable = true;
      settings = {
        LogLevel = "VERBOSE";
        PermitRootLogin = "yes";
        PasswordAuthentication = if cfg.allowRootPasswordLogin then true else false;
      };
    };

    # Ensure SSH key pair generation for non-root users
    systemd.services = lib.mapAttrs' (name: _: {
      name = "generate_ssh_key_${name}";
      value = {
        description = "Generate SSH key pair for ${name}";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = name;
          Type = "oneshot";
        };
        script = ''
          #!/run/current-system/sw/bin/bash
          if [ ! -f /home/${name}/.ssh/id_ed25519 ]; then
            if [ -v DRY_RUN ]; then
              echo "DRY_RUN is set. Would generate SSH key for ${name}.";
            else
              echo "Generating SSH key for ${name}.";
              mkdir -p /home/${name}/.ssh;
              chmod 700 /home/${name}/.ssh;
              /run/current-system/sw/bin/ssh-keygen -t ed25519 -f /home/${name}/.ssh/id_ed25519 -N "";
            fi
          else
            echo "SSH key already exists for ${name}.";
          fi
        '';
      };
    }) users_cfg.users;
  };
}
