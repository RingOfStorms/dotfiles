# Opengist (https://github.com/thomiceli/opengist): gist.joshuabell.xyz.
# Was a host oci-container on h001 (hosts/h001/containers/opengist.nix).
#
# Data: /srv/containers/opengist/data = the old /var/lib/opengist (sqlite
# db, git repos, index, secret key, sessions). Files are owned by uid 1000,
# the image's runtime user; the idmapped volume keeps that on disk.
{
  name = "opengist";
  kind = "podman";
  description = "Opengist pastebin (gist.joshuabell.xyz)";
  host = "h001";

  persist = {
    data = "/opengist";
  };

  podman = {
    # Pinned; bump deliberately (opengist migrates its db on upgrade, take a
    # `cnt backup opengist` first).
    image = "ghcr.io/thomiceli/opengist:1.10.0";
    ports = [ "6157:6157" ]; # 127.0.0.1 only; nginx below fronts it
    environment = {
      OG_LOG_LEVEL = "info";
    };
  };

  # SQLite: stop for a consistent backup (`cnt backup opengist` asks).

  # o002 terminates TLS for the public name and proxies to h001:80 over the
  # tailnet; LAN/tailnet clients may hit h001:443 directly (wildcard cert).
  nginx = ''
    server {
      listen 80;
      listen [::]:80;
      listen 443 ssl;
      listen [::]:443 ssl;
      server_name gist.joshuabell.xyz;
      ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;
      ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;
      client_max_body_size 64m;
      location / {
        proxy_pass http://127.0.0.1:6157;
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
