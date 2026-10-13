# Forgejo (git.joshuabell.xyz) + its PostgreSQL 17, one container.
# Was hosts/h001/containers/forgejo.nix (private-network nixos container,
# 10.0.0.2). Host network now: HTTP on 127.0.0.1:3000 behind nginx, builtin
# SSH directly on 0.0.0.0:3032 (o002 streams public :3032 here over the
# tailnet; replaces the old h001 nginx stream).
{
  name = "forgejo";
  kind = "nixos";
  description = "Forgejo git forge (git.joshuabell.xyz, ssh :3032)";
  host = "h001";

  persist = {
    data = "/var/lib/forgejo"; # repositories, custom/conf/app.ini + secrets, lfs, avatars
    postgres = "/var/lib/postgresql/17";
    pgdumps = "/var/backup/postgresql"; # nightly postgresqlBackup
    nixos = "/var/lib/nixos";
  };

  tcpPorts = [ 3032 ];

  backupHook = "runuser -u postgres -- pg_dumpall > /var/backup/postgresql/cnt-dumpall.sql";

  nginx = ''
    server {
      listen 80;
      listen [::]:80;
      listen 443 ssl;
      listen [::]:443 ssl;
      server_name git.joshuabell.xyz;
      ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;
      ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;
      client_max_body_size 1g;
      location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
      }
    }
  '';
}
