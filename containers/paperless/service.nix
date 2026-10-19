# Paperless-ngx (docs.joshuabell.xyz, tailnet-only): web + celery + tika +
# gotenberg + PostgreSQL 16 + redis, one container. Was
# hosts/h001/containers/paperless.nix (private-network container 10.0.0.7).
# media/ and consume/ stay on /drives/wd10 via binds in flake.nix; the
# paperless dataDir (index, classifier, secret key) and DB persist on
# /srv/containers.
{
  name = "paperless";
  kind = "nixos";
  description = "Paperless-ngx documents (docs.joshuabell.xyz)";
  host = "h001";
  requires = [ "wd10" ];

  persist = {
    data = "/var/lib/paperless"; # index, classification model, secret key
    postgres = "/var/lib/postgresql/16";
    pgdumps = "/var/backup/postgresql"; # nightly postgresqlBackup + backupHook
    nixos = "/var/lib/nixos";
  };

  backupHook = "runuser -u postgres -- pg_dumpall > /var/backup/postgresql/cnt-dumpall.sql";

  # Tailnet-only (not proxied by o002); the allow/deny keeps that enforced in
  # nginx until the internal listener split (ROUTING-PLAN §2.3).
  routes.web = {
    port = 28981;
    name = "docs";
    exposure = "tailnet";
    auth = "native";
    maxBody = "100M";
    timeouts = "600s";
    extraConfig = ''
      proxy_set_header X-Forwarded-Host $host;
      send_timeout 600s;
      allow 100.64.0.0/10;
      allow 127.0.0.0/8;
      deny all;
    '';
  };
}
