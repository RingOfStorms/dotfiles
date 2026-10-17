# Zitadel SSO (sso.joshuabell.xyz) + its PostgreSQL 17, one container.
# Was hosts/h001/containers/zitadel.nix (private-network nixos container,
# 10.0.0.3:8080). Host network now: zitadel on :8085 (127.0.0.1:8080 is
# life's), postgres on its unix socket only (h001's own postgres owns :5432).
#
# Everyone (sec, life, open-webui, trilium, every sec-agent) logs in
# here, so a broken zitadel locks the fleet out of sec. Break-glass: the
# masterkey and pg dumps are in restic (persist below) and in the offline kit.
{
  name = "zitadel";
  kind = "nixos";
  description = "Zitadel SSO (sso.joshuabell.xyz)";
  host = "h001";

  persist = {
    # PG 17 cluster in ./17, copied 1:1 from /var/lib/zitadel/postgres.
    postgresql = "/var/lib/postgresql";
    pgdumps = "/var/backup/postgresql"; # nightly postgresqlBackup + backupHook dump
    # masterkey (32 bytes). Irreplaceable: without it the DB's encrypted
    # columns are unreadable. Lives in persist so it travels with moves and
    # backups. Not served by sec-agent on purpose (sec logs in via zitadel).
    keys = "/var/lib/zitadel-keys";
    nixos = "/var/lib/nixos";
  };

  backupHook = "set -o pipefail; runuser -u postgres -- pg_dumpall | gzip > /var/backup/postgresql/cnt-dumpall.sql.gz";

  # Same X-Forwarded-Proto https as before: o002 terminates TLS and forwards
  # plain http over the tailnet; zitadel must still believe it is https.
  nginx = ''
    server {
      listen 80;
      listen [::]:80;
      listen 443 ssl;
      listen [::]:443 ssl;
      server_name sso.joshuabell.xyz;
      ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;
      ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;
      location / {
        proxy_pass http://127.0.0.1:8085;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 60s;
      }
    }
  '';
}
