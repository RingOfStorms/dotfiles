# Dawarich location history (location.joshuabell.xyz): Rails + sidekiq +
# PostgreSQL 17/postgis + redis, one container. The host's restic job backs
# up data + pgdumps.
{
  name = "dawarich";
  kind = "nixos";
  description = "Dawarich location history (location.joshuabell.xyz)";

  persist = {
    data = "/var/lib/dawarich"; # uploads/imports, storage, secrets/secret-key-base
    postgres = "/var/lib/postgresql/17";
    pgdumps = "/var/backup/postgresql"; # nightly postgresqlBackup
    redis = "/var/lib/redis-dawarich"; # sidekiq queue (scheduled jobs)
    nixos = "/var/lib/nixos";
  };

  backupHook = "runuser -u postgres -- pg_dumpall > /var/backup/postgresql/cnt-dumpall.sql";

  # Login breaks on duplicate X-Forwarded-Proto/Host headers; the generated
  # vhost sends each once.
  # puma binds :3001 in its private netns (BINDING in container.nix).
  net = {
    private = true;
    index = 10;
  };

  routes.web = {
    group = "Personal";
    port = 3001;
    name = "location";
    exposure = "public";
    auth = "native";
    maxBody = "50G";
    timeouts = "600s";
    extraConfig = ''
      proxy_set_header X-Forwarded-Host $host;
      send_timeout 600s;
    '';
  };
}
