# atuin shell-history sync server (atuin.joshuabell.xyz).
# Was a private-network nixos container in hosts/h001/containers/atuin.nix.
{
  name = "atuin";
  kind = "nixos";
  description = "atuin shell-history sync server (atuin.joshuabell.xyz)";
  host = "h001";

  persist = {
    # PG 17 cluster in ./17 (copied 1:1 from the old /var/lib/atuin/postgres)
    # plus dumpall.sql from backupHook.
    postgresql = "/var/lib/postgresql";
    nixos = "/var/lib/nixos"; # uid/gid map, keeps file owners stable
  };

  # Consistent SQL dump that travels with backups/moves.
  backupHook = "runuser -u postgres -- pg_dumpall > /var/lib/postgresql/dumpall.sql";

  # atuin listens on 127.0.0.1:8888 (host network); only nginx is exposed.
  # o002 terminates TLS for the public name and proxies to h001:80 over the
  # tailnet; tailnet clients may hit h001:443 directly (wildcard cert).
  nginx = ''
    server {
      listen 80;
      listen [::]:80;
      listen 443 ssl;
      listen [::]:443 ssl;
      server_name atuin.joshuabell.xyz;
      ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;
      ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;
      client_max_body_size 64m;
      location / {
        proxy_pass http://127.0.0.1:8888;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      }
    }
  '';
}
