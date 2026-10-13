# Open WebUI (chat.joshuabell.xyz) on 127.0.0.1:8084. Talks to litellm
# (127.0.0.1:8094) and searx (127.0.0.1:8889), both host-network containers.
# Was hosts/h001/mods/openwebui.nix on bare metal.
{
  name = "open-webui";
  kind = "nixos";
  description = "Open WebUI (chat.joshuabell.xyz)";
  host = "h001";

  persist = {
    data = "/var/lib/private/open-webui"; # DynamicUser state (webui.db, uploads, vector db)
    nixos = "/var/lib/nixos";
  };

  nginx = ''
    server {
      listen 80;
      listen [::]:80;
      listen 443 ssl;
      listen [::]:443 ssl;
      server_name chat.joshuabell.xyz;
      ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;
      ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;
      location / {
        proxy_pass http://127.0.0.1:8084;
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
