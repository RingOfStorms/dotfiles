# Guest config. Host network: immich-server on 127.0.0.1:2283, ML on
# localhost:3003, postgres and redis on unix sockets. uids pinned to the
# copied data (immich 916; postgres is 71 by default).
{
  pkgs,
  lib,
  ...
}:
{
  system.stateVersion = "25.05";

  users.users.immich.uid = 916;
  users.groups.immich.gid = 916;

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;
    enableJIT = true;
    dataDir = "/var/lib/postgresql/16";
    # Host network: the host's postgres owns 5432; unix socket only.
    settings.listen_addresses = lib.mkForce "";
    authentication = lib.mkForce ''
      local all all trust
    '';
    ensureDatabases = [ "immich" ];
    ensureUsers = [
      {
        name = "immich";
        ensureDBOwnership = true;
        ensureClauses.login = true;
      }
    ];
  };
  services.postgresqlBackup.enable = true;
  # The immich module adds pgvector + vectorchord and the vchord preload
  # itself when database.enable = true; don't override.

  services.immich = {
    enable = true;
    host = "127.0.0.1";
    port = 2283;
    mediaLocation = "/var/lib/immich";
    database = {
      enable = true;
      createDB = false; # ensureDatabases above
      name = "immich";
      user = "immich";
    };
    redis.enable = true; # unix socket
    machine-learning.enable = true;
    settings = {
      server.externalDomain = "https://photos.joshuabell.xyz";
      newVersionCheck.enabled = false;
    };
  };
  systemd.services.immich-server = {
    requires = [ "postgresql.service" ];
    after = [ "postgresql.service" ];
  };
}
