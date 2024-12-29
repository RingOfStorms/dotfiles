{
  config,
  lib,
  ...
}:
with lib;
{
  config = {
    # Use fail2ban
    services.fail2ban = {
      enable = true;
    };

    # Open ports in the firewall if enabled.
    networking.firewall.allowedTCPPorts = mkIf config.mods.common.sshPortOpen [
      22 # sshd
    ];

    # Enable the OpenSSH daemon.
    services.openssh = {
      enable = true;
      settings = {
        LogLevel = "VERBOSE";
        PermitRootLogin = "yes";
      };
    };

    # Ensure SSH key pair generation for non-root users
    systemd.services = mapAttrs' (name: _: {
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
    }) config.mods.common.users;
  };
}
