# Metadata for the minecraft service. Plain data: read by ../flake.nix
# (inventory for the `containers` CLI) and by ./flake.nix (container build).
{
  name = "minecraft";
  kind = "nixos";
  description = "Velocity proxy + Paper survival/creative, LuckPerms on PostgreSQL, squaremap";

  # Kept across restarts, on the host at /srv/containers/minecraft/<key>.
  # Everything else in the container is wiped on every start.
  persist = {
    srv = "/srv/minecraft"; # worlds, plugins, velocity data
    secrets = "/var/lib/minecraft-secrets"; # velocity forwarding secret
    postgresql = "/var/lib/postgresql"; # LuckPerms database
    nixos = "/var/lib/nixos"; # uid/gid map, keeps file owners stable
  };

  # Private network: the guest is 10.233.18.2 on every host. Only the route
  # ports below reach it (guest firewall); postgres and the Paper backends
  # stay on the guest's own loopback. net.index is fleet-wide unique, never
  # reused (12 was beszel).
  net = {
    private = true;
    index = 18;
  };

  # Velocity: the only port players use. Public through the router: h005
  # DNATs WAN :25565 to the placed host's LAN IP (fleet-edge's runtime
  # forwards), and that host DNATs :25565 on to the guest (ports file
  # `tcp 25565 dnat 10.233.18.2`, fleet-net-nat @routes). The home IP is
  # exposed for this name. Players connect to minecraft.joshuabell.xyz
  # (CNAME home). Auth: Velocity online-mode (Mojang accounts) + whitelist.
  routes.game = {
    port = 25565;
    proto = "tcp";
    exposure = "public";
    auth = "native";
    via = [ "router" ];
  };

  # squaremap (survival), read-only web map on :8080, proxied by the host
  # nginx to 10.233.18.2:8080. Public via the edge at
  # https://computerboyz.joshuabell.xyz/.
  routes.web = {
    port = 8080;
    name = "computerboyz";
    exposure = "public";
    auth = "none";
    publicWithoutAuth = true; # read-only map, no accounts
    group = "Games";
  };

  # Run before stop when backing up / moving. Output: SQL dump in a
  # persisted dir so it travels with the data.
  backupHook = "runuser -u postgres -- pg_dumpall > /var/lib/postgresql/dumpall.sql";

  # `containers attach minecraft`
  attach = "tmux attach -t mc";
}
