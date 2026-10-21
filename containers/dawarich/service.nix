# Dawarich location history (location.joshuabell.xyz): Rails + sidekiq +
# PostgreSQL 17/postgis + redis, one container. Was
# hosts/h001/containers/dawarich.nix (private-network container 10.0.0.5,
# data on /drives/wd10/dawarich). Now on /srv/containers (nvme, ~1.6 GB);
# h001's restic job backs up data + pgdumps from there.
{
  name = "dawarich";
  kind = "nixos";
  description = "Dawarich location history (location.joshuabell.xyz)";
  host = "h001";

  persist = {
    data = "/var/lib/dawarich"; # uploads/imports, storage, secrets/secret-key-base
    postgres = "/var/lib/postgresql/17";
    pgdumps = "/var/backup/postgresql"; # nightly postgresqlBackup
    redis = "/var/lib/redis-dawarich"; # sidekiq queue (scheduled jobs)
    nixos = "/var/lib/nixos";
  };

  backupHook = "runuser -u postgres -- pg_dumpall > /var/backup/postgresql/cnt-dumpall.sql";

  # Generated vhost sends each header once (duplicate X-Forwarded-Proto/Host
  # broke login before).
  # puma binds 127.0.0.1:3001 (BINDING in container.nix).
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
