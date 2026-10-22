# Guest config. Private network: puma on :3001 (BINDING; host nginx
# fronts it); postgres and redis on unix sockets only. uids pinned to match the copied data.
{
  config,
  pkgs,
  lib,
  fleetNet,
  ...
}:
{
  system.stateVersion = "25.05";

  users.users.dawarich.uid = 977;
  users.groups.dawarich.gid = 977;
  users.users.redis-dawarich.uid = 976;
  users.groups.redis-dawarich.gid = 976;

  services.postgresql = {
    enable = true;
    # Dawarich requires PostGIS for geospatial features
    package = pkgs.postgresql_17.withPackages (p: [ p.postgis ]);
    enableJIT = true;
    extensions = ps: [ ps.postgis ];
    dataDir = "/var/lib/postgresql/17";
    settings.listen_addresses = lib.mkForce "";
    authentication = lib.mkForce ''
      local all all trust
    '';
    ensureDatabases = [ "dawarich" ];
    ensureUsers = [
      {
        name = "dawarich";
        ensureDBOwnership = true;
        ensureClauses.login = true;
      }
    ];
  };
  services.postgresqlBackup.enable = true;

  services.dawarich = {
    enable = true;
    webPort = 3001;
    localDomain = "location.joshuabell.xyz";
    configureNginx = false; # host nginx proxies (service.nix)
    database = {
      createLocally = false; # created via ensureDatabases above
      host = "/var/run/postgresql";
      name = "dawarich";
      user = "dawarich";
    };
    redis.createLocally = true; # unix socket
    secretKeyBaseFile = "/var/lib/dawarich/secrets/secret-key-base";
    automaticMigrations = true;
    sidekiqThreads = 5;
    environment = {
      DISABLE_REGISTRATION = "false";
      # The module hardcodes APPLICATION_PROTOCOL=http; behind TLS that breaks
      # login (CSRF origin mismatch) and ActionCable websockets.
      APPLICATION_PROTOCOL = "https";
      # 0.0.0.0 in the private netns, 127.0.0.1 on the host network.
      BINDING = fleetNet.bindAddress;
    };
  };

  # Ensure postgis exists before dawarich-init-db runs (initialScript only
  # runs on first cluster creation).
  systemd.services.dawarich-postgis-init = {
    description = "Initialize PostGIS extension for Dawarich";
    requires = [ "postgresql.service" ];
    after = [ "postgresql.service" ];
    before = [ "dawarich-init-db.service" ];
    requiredBy = [ "dawarich-init-db.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
      Group = "postgres";
      ExecStart = pkgs.writeShellScript "dawarich-postgis-init" ''
        ${config.services.postgresql.package}/bin/psql -d dawarich -c "CREATE EXTENSION IF NOT EXISTS postgis;"
      '';
    };
  };
}
