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
  };

  backupHook = "runuser -u postgres -- pg_dumpall > /var/backup/postgresql/cnt-dumpall.sql";

  # recommendedProxySettings is NOT applied to these include files; headers explicit.
  nginx = ''
    server {
      listen 80;
      listen [::]:80;
      listen 443 ssl;
      listen [::]:443 ssl;
      server_name photos.joshuabell.xyz;
      ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;
      ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;
      client_max_body_size 100G;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      send_timeout 600s;
      location / {
        proxy_pass http://127.0.0.1:2283;
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
