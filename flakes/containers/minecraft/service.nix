# Metadata for the minecraft service. Plain data: read by ../flake.nix
# (inventory for the `boxes` CLI) and by ./flake.nix (container build).
{
  name = "minecraft";
  kind = "nixos";
  description = "Velocity proxy + Paper survival/creative, LuckPerms on PostgreSQL, squaremap";

  # Where it should run. `boxes move` moves the data; then update this line
  # and push.
  host = "h003";

  # Kept across restarts, on the host at /srv/containers/minecraft/<key>.
  # Everything else in the container is wiped on every start.
  persist = {
    srv = "/srv/minecraft"; # worlds, plugins, velocity data
    secrets = "/var/lib/minecraft-secrets"; # velocity forwarding secret
    postgresql = "/var/lib/postgresql"; # LuckPerms database
    nixos = "/var/lib/nixos"; # uid/gid map, keeps file owners stable
  };

  # Opened in the host firewall at deploy time (container shares host network).
  tcpPorts = [ 25565 ];

  # Written to /var/lib/boxes/nginx/minecraft.conf on the host.
  # @OVERLAY_IP@ is replaced with the host's tailscale IP from hosts/fleet.nix.
  # o002 terminates TLS for computerboyz.joshuabell.xyz and proxies here.
  nginx = ''
    server {
      listen @OVERLAY_IP@:80;
      server_name computerboyz.joshuabell.xyz;
      location / { return 444; }
      location /map/survival/ {
        proxy_pass http://127.0.0.1:8080/;
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

  # Run before stop when backing up / moving. Output: SQL dump in a
  # persisted dir so it travels with the data.
  backupHook = "runuser -u postgres -- pg_dumpall > /var/lib/postgresql/dumpall.sql";

  # `boxes attach minecraft`
  attach = "tmux attach -t mc";
}
