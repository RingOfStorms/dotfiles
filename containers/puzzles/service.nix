# Puzzles server (puzzles.joshuabell.xyz), 127.0.0.1:8093.
# Was hosts/h001/mods/puzzles.nix on bare metal.
{
  name = "puzzles";
  kind = "nixos";
  description = "Puzzles server (puzzles.joshuabell.xyz)";
  host = "h001";

  persist = {
    data = "/var/lib/puzzles-server"; # data.db, auxiliary.db, storage/
    nixos = "/var/lib/nixos";
  };

  nginx = ''
    server {
      listen 80;
      listen [::]:80;
      listen 443 ssl;
      listen [::]:443 ssl;
      server_name puzzles.joshuabell.xyz;
      ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;
      ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;
      location / {
        proxy_pass http://127.0.0.1:8093;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
      }
    }
  '';
}
