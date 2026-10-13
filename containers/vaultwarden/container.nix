# Guest config. Host network: vaultwarden on 127.0.0.1:8222.
{ lib, ... }:
{
  system.stateVersion = "24.11";

  # Same ids as the old container / o001, so the copied files keep working.
  users.users.vaultwarden.uid = 114;
  users.groups.vaultwarden.gid = 114;

  services.vaultwarden = {
    enable = true;
    dbBackend = "sqlite";
    backupDir = "/var/lib/backups/vaultwarden";
    # Bind-mounted read-only from h001's sec-agent output (see flake.nix).
    environmentFile = "/var/secrets/vaultwarden.env";
    config = {
      DOMAIN = "https://vault.joshuabell.xyz";
      SIGNUPS_ALLOWED = false;
      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT = 8222;
    };
  };
}
