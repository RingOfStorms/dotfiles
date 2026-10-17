# sec — the fleet secrets manager server (secrets.joshuabell.xyz).
# Was hosts/h001/mods/sec.nix (bare-metal systemd unit). Host network:
# 127.0.0.1:8300 behind nginx, same as before.
#
# Bootstrap: every host's sec-agent (h001's included) fetches from here and
# logs in via zitadel. Agents keep their hydrated cache, so a short outage is
# harmless; a lost db.key is not (break-glass copy is offline + in restic).
{
  name = "sec";
  kind = "nixos";
  description = "sec secrets manager server (secrets.joshuabell.xyz)";
  host = "h001";

  persist = {
    # sec.db + db.key (0400 root). The SQLite file is snapshotted by the
    # host's restic prepare step (generic /srv/containers scan); db.key is
    # backed up as a plain file from here.
    data = "/var/lib/secrets_manager";
    nixos = "/var/lib/nixos";
  };

  # Dumb proxy, as the old module vhost: the origin authenticates every route.
  nginx = ''
    server {
      listen 80;
      listen [::]:80;
      listen 443 ssl;
      listen [::]:443 ssl;
      server_name secrets.joshuabell.xyz;
      ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;
      ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;
      client_max_body_size 64k;
      location / {
        proxy_pass http://127.0.0.1:8300;
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
