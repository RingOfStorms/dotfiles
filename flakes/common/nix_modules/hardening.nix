{
  config,
  lib,
  pkgs,
  ...
}:
{
  environment.systemPackages = with pkgs; [
    openssh
    autossh
  ];

  # name this computer
  networking = {
    # hostName = top_cfg.systemName;
    nftables.enable = true;
    # Clears firewall rules on reboot, only ones set in config will be remade
    nftables.flushRuleset = true;
    firewall.enable = true;
  };

  # TODO invesitgate onensnitch usage and rules I may want. It is cumbersome with flushRuleset above...
  # services.opensnitch = {
  #   enable = true;
  #   settings = {
  #     Firewall = if config.networking.nftables.enable then "nftables" else "iptables";
  #     InterceptUknown = true;
  #     ProcMonitorMethod = "ebpf";
  #     DefaultAction = "deny";
  #   };
  #   rules = {
  #
  #   };
  # };

  # Use fail2ban
  services.fail2ban = {
    enable = true;
    # Ignore my tailnet
    ignoreIP = [
      "100.64.0.0/10"
    ];
  };

  # Open ports in the firewall if enabled.
  networking.firewall.allowedTCPPorts = [
    22 # sshd
  ];

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    settings = {
      LogLevel = "VERBOSE";
      # TODO revisit allowing root login
      PermitRootLogin = "yes";
      PasswordAuthentication = false;
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
  }) config.users.users;
}
