# Guest config. Private network (service.nix net): vaultwarden on :8222.
{ lib, fleetNet, ... }:
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
      ROCKET_ADDRESS = fleetNet.bindAddress;
      ROCKET_PORT = 8222;
    };
  };
}
