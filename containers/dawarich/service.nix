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

  # recommendedProxySettings is NOT applied to these include files, so each
  # header is sent once (duplicate X-Forwarded-Proto/Host broke login before).
  nginx = ''
    server {
      listen 80;
      listen [::]:80;
      listen 443 ssl;
      listen [::]:443 ssl;
      server_name location.joshuabell.xyz;
      ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;
      ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;
      client_max_body_size 50G;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      send_timeout 600s;
      location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto https;
      }
    }
  '';
}
