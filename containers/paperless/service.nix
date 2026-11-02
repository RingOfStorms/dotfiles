# Paperless-ngx (docs.joshuabell.xyz, tailnet-only): web + celery + tika +
# gotenberg + PostgreSQL 16 + redis, one container.
# media/ and consume/ stay on /drives/wd10 via binds in flake.nix; the
# paperless dataDir (index, classifier, secret key) and DB persist on
# /srv/containers.
{
  name = "paperless";
  kind = "nixos";
  description = "Paperless-ngx documents (docs.joshuabell.xyz)";
  requires = [ "wd10" ];

  persist = {
    data = "/var/lib/paperless"; # index, classification model, secret key
    postgres = "/var/lib/postgresql/16";
    pgdumps = "/var/backup/postgresql"; # nightly postgresqlBackup + backupHook
    nixos = "/var/lib/nixos";
  };

  backupHook = "runuser -u postgres -- pg_dumpall > /var/backup/postgresql/cnt-dumpall.sql";

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
