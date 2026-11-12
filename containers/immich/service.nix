# Immich photos (photos.joshuabell.xyz, public via o002): server + ML (CPU)
# + PostgreSQL 16 (vectorchord) + redis, one container.
# Media (upload/library, ~420G without the regenerable thumbs and
# encoded-video) lives on /srv/bulk/immich/media (capability `bulk`), bound in
# by flake.nix and backed up as an extraPath; DB + ML cache persist on
# /srv/containers.
{
  name = "immich";
  kind = "nixos";
  description = "Immich photos (photos.joshuabell.xyz)";
  requires = [ "bulk" ];

  persist = {
    postgres = "/var/lib/postgresql/16";
    pgdumps = "/var/backup/postgresql"; # nightly postgresqlBackup + backup.hooks.pre
    mlcache = "/var/cache/immich"; # ML models (re-downloadable)
    nixos = "/var/lib/nixos";
    dbro = "/var/lib/immich-dbro"; # immich_ro password (tailnet read-only DB access)
  };

  backup.hooks.pre = "runuser -u postgres -- pg_dumpall > /var/backup/postgresql/cnt-dumpall.sql";
  # regenerable ML models
  backup.exclude = [ "mlcache" ];
  backup.extraPaths = [
    {
      path = "/srv/bulk/immich/media";
      requires = "bulk";
      # regenerable (immich rebuilds them from the originals)
      exclude = [
        "thumbs"
        "encoded-video"
      ];
      # immich writes .immich into each media folder; missing = disk not
      # mounted (h001) or data not synced, so the backup refuses.
      sentinel = "/srv/bulk/immich/media/upload/.immich";
    }
  ];

  # net.index is fleet-wide unique.
  net = {
    private = true;
    index = 15;
  };

  # postgres (immich_ro) and ML (unauthenticated) for immich_manager on lio:
  # DNAT only for h001's overlay IP and only from lio's (allow).
  routes.pg = {
    port = 5432;
    proto = "tcp";
    exposure = "tailnet";
    auth = "native";
    allow = [ "lio" ];
  };
  routes.ml = {
    port = 3003;
    proto = "tcp";
    exposure = "tailnet";
    auth = "none";
    allow = [ "lio" ];
  };

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
    # Strict per-IP rate limit + fail2ban on o002 (lib.nix edgeLogin).
    loginPaths = [
      "/api/auth/login"
      "/api/auth/admin-sign-up"
    ];
  };
}
