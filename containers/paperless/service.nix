# Paperless-ngx (docs.joshuabell.xyz, tailnet-only): web + celery + tika +
# gotenberg + PostgreSQL 16 + redis, one container.
# media/ and consume/ live on /srv/bulk/paperless (capability `bulk`),
# bound in by flake.nix and backed up as extraPaths; the
# paperless dataDir (index, classifier, secret key) and DB persist on
# /srv/containers.
{
  name = "paperless";
  kind = "nixos";
  description = "Paperless-ngx documents (docs.joshuabell.xyz)";
  requires = [ "bulk" ];

  persist = {
    data = "/var/lib/paperless"; # index, classification model, secret key
    postgres = "/var/lib/postgresql/16";
    pgdumps = "/var/backup/postgresql"; # nightly postgresqlBackup + backup.hooks.pre
    nixos = "/var/lib/nixos";
  };

  backup.hooks.pre = "runuser -u postgres -- pg_dumpall > /var/backup/postgresql/cnt-dumpall.sql";
  # search index, rebuilt by document_index reindex
  backup.exclude = [ "data/index" ];
  backup.extraPaths = [
    {
      path = "/srv/bulk/paperless/media";
      requires = "bulk";
      exclude = [ "documents/thumbnails" ]; # regenerable
      # paperless keeps this lock file; missing = disk not mounted or not synced
      sentinel = "/srv/bulk/paperless/media/media.lock";
    }
    {
      # ingestion queue, legitimately empty
      path = "/srv/bulk/paperless/consume";
      requires = "bulk";
    }
  ];

  net = {
    private = true;
    index = 9;
  };
  # paperless runs local Tika/Gotenberg/classifier; no outbound
  # internet needed.
  internet = false;

  routes.web = {
    group = "Productivity";
    port = 28981;
    name = "docs";
    exposure = "tailnet";
    auth = "native";
    maxBody = "100M";
    timeouts = "600s";
    extraConfig = ''
      proxy_set_header X-Forwarded-Host $host;
      send_timeout 600s;
    '';
  };
}
