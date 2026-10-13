# Guest config: services.life copied from hosts/h001/containers/life.nix.
# Host network: life on 127.0.0.1:8080; postgres on its unix socket only (the
# host's own postgres owns 127.0.0.1:5432).
{ lib, life, ... }:
{
  imports = [ life.nixosModules.default ];
  system.stateVersion = "26.05";

  # Same ids as before, so the copied files keep working.
  users.users.life.uid = 917;
  users.groups.life.gid = 917;
  # postgres is 71 by default (config.ids).

  services.postgresql.settings.listen_addresses = lib.mkForce "";

  services.life = {
    enable = true;
    publicOrigin = "https://life.joshuabell.xyz";
    listen = "127.0.0.1:8080";
    # h001's nginx sets X-Forwarded-For (see service.nix).
    trustForwardedFor = true;

    zitadel = {
      issuer = "https://sso.joshuabell.xyz";
      projectId = "384694626893692931";
      webClientId = "393057818401374211";
      nativeClientId = "393057674100539395";
    };

    backup = {
      pgbackrest = {
        enable = true;
        secretsFile = "/run/secrets/life-pgbackrest.conf";
      };
      nightly = {
        enable = true;
        restic.environmentFiles = [ "/run/secrets/life-backup.env" ];
      };
    };
  };
}
