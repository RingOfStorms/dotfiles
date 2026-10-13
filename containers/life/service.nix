# Life server (life.joshuabell.xyz): Rust server + PostgreSQL 18 +
# pgBackRest + nightly restic, in one container on 127.0.0.1:8080.
# Was hosts/h001/containers/life.nix (private-network nixos container).
#
# APK releases: publish to root@h001:/srv/containers/life/state/releases
# (was /var/lib/life/state/releases).
{
  name = "life";
  kind = "nixos";
  description = "Life server (life.joshuabell.xyz)";
  host = "h001";

  persist = {
    state = "/var/lib/life"; # blobs, releases, nightly logical backups
    postgres = "/var/lib/postgresql/18";
    pgbackrest = "/var/lib/pgbackrest"; # local encrypted repo1
    nixos = "/var/lib/nixos";
  };

  # Logical dump that travels with cnt backups/moves (pgBackRest repo too).
  backupHook = "mkdir -p /var/lib/life/backups && runuser -u postgres -- pg_dumpall > /var/lib/life/backups/cnt-dumpall.sql";

  # Client IP: public traffic is client -> o002 nginx -> (tailnet) here; trust
  # only o002 (100.64.0.5) for X-Forwarded-For, Life takes the last entry.
  nginx = ''
    server {
      listen 80;
      listen [::]:80;
      listen 443 ssl;
      listen [::]:443 ssl;
      server_name life.joshuabell.xyz;
      ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;
      ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;
      set_real_ip_from 100.64.0.5;
      real_ip_header X-Forwarded-For;
      location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        # Blob uploads up to 100 MiB, streamed; long downloads / live sync.
        client_max_body_size 110m;
        proxy_request_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
      }
    }
  '';
}
