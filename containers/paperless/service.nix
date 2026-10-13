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

  # recommendedProxySettings is NOT applied to these include files; headers explicit.
  nginx = ''
    server {
      listen 80;
      listen [::]:80;
      listen 443 ssl;
      listen [::]:443 ssl;
      server_name docs.joshuabell.xyz;
      ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;
      ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;
      # Tailnet-only: overlay network and localhost.
      allow 100.64.0.0/10;
      allow 127.0.0.0/8;
      deny all;
      client_max_body_size 100M;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      send_timeout 600s;
      location / {
        proxy_pass http://127.0.0.1:28981;
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
