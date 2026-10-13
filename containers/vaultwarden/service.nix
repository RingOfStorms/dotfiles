# vaultwarden (vault.joshuabell.xyz). SQLite, single-user vault.
# Was a private-network nixos container in hosts/h001/containers/vaultwarden.nix;
# data copied 1:1 (uid/gid 114 kept inside the container).
{
  name = "vaultwarden";
  kind = "nixos";
  description = "vaultwarden password manager (vault.joshuabell.xyz)";
  host = "h001";

  persist = {
    data = "/var/lib/vaultwarden"; # db.sqlite3, rsa_key, attachments, sends
    backups = "/var/lib/backups/vaultwarden"; # nightly backup-vaultwarden copy
    nixos = "/var/lib/nixos";
  };

  # Consistent SQLite copy next to the live db, so a restore never depends
  # on the WAL state of the stopped copy.
  backupHook = "systemctl start backup-vaultwarden.service";

  # vaultwarden listens on 127.0.0.1:8222 (host network). o002 terminates TLS
  # for the public name and proxies to h001:80 over the tailnet.
  nginx = ''
    server {
      listen 80;
      listen [::]:80;
      listen 443 ssl;
      listen [::]:443 ssl;
      server_name vault.joshuabell.xyz;
      ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;
      ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;
      client_max_body_size 525m;
      location / {
        proxy_pass http://127.0.0.1:8222;
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
