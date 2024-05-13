{ settings, pkgs, ... }:
{
  # [Unit]
  # Description=Nixserver Agent
  # After=network.target

  # [Service]
  # ExecStart=/usr/local/bin/nixserver agent run
  # Restart=always
  # User=luser
  # Group=luser

  # [Install]
  # WantedBy=multi-user.target

  systemd.services.nixserver_agent = {
    description = "Nixserver Agent";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Environment = "PATH=/run/wrappers/bin:/home/luser/.nix-profile/bin:/nix/profile/bin:/home/luser/.local/state/nix/profile/bin:/etc/profiles/per-user/luser/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin";
      ExecStart = "/usr/local/bin/nixserver agent run";
      Restart = "always";
      User = "luser";
    };
  };
}
