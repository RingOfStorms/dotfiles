# Immich photos (photos.joshuabell.xyz, public via o002): server + ML (CPU)
# + PostgreSQL 16 (vectorchord) + redis, one container. Was
# hosts/h001/containers/immich.nix (private-network container 10.0.0.4).
# Media (library/upload/thumbs, ~1.7T with paperless) stays on /drives/wd10
# via a bind in flake.nix; DB + ML cache persist on /srv/containers.
{
  name = "immich";
  kind = "nixos";
  description = "Immich photos (photos.joshuabell.xyz)";
  host = "h001";
  requires = [ "wd10" ];

  persist = {
    postgres = "/var/lib/postgresql/16";
    pgdumps = "/var/backup/postgresql"; # nightly postgresqlBackup + backupHook
    mlcache = "/var/cache/immich"; # ML models (re-downloadable)
    nixos = "/var/lib/nixos";
    dbro = "/var/lib/immich-dbro"; # immich_ro password (tailnet read-only DB access)
  };

  backupHook = "runuser -u postgres -- pg_dumpall > /var/backup/postgresql/cnt-dumpall.sql";

  # Only the web vhost is a route. postgres *:5432 (immich_ro, tailnet) and
  # ML *:3003 (unauthenticated) stay undeclared on purpose: a tailnet tcp
  # route would add them to the ports file, which opens them on every
  # interface, wider than today (tailscale0 only, via its trust).
  routes.web = {
    group = "Media";
    port = 2283;
    name = "photos";
    exposure = "public";
    auth = "native";
    maxBody = "100G";
    timeouts = "600s";
    extraConfig = ''
      proxy_set_header X-Forwarded-Host $host;
      send_timeout 600s;
    '';
  };
}
