# Metadata for the minecraft service. Plain data: read by ../flake.nix
# (inventory for the `containers` CLI) and by ./flake.nix (container build).
{
  name = "minecraft";
  kind = "nixos";
  description = "Velocity proxy + Paper survival/creative, LuckPerms on PostgreSQL, squaremap";

  # Where it should run. `containers move` moves the data; then update this line
  # and push. null: INACTIVE since 2026-10-15 (see README.md); the CLI refuses
  # to act on it without an explicit --host.
  host = null;

  # Kept across restarts, on the host at /srv/containers/minecraft/<key>.
  # Everything else in the container is wiped on every start.
  persist = {
    srv = "/srv/minecraft"; # worlds, plugins, velocity data
    secrets = "/var/lib/minecraft-secrets"; # velocity forwarding secret
    postgresql = "/var/lib/postgresql"; # LuckPerms database
    nixos = "/var/lib/nixos"; # uid/gid map, keeps file owners stable
  };

  # Velocity: the only port players use. Public through the router (h005
  # DNATs WAN :25565 to the host's LAN IP; containers/lib.nix
  # routerForwards), so the home IP is exposed for this name. Players
  # connect to minecraft.joshuabell.xyz (CNAME home). Auth: Velocity
  # online-mode (Mojang accounts) + whitelist.
  routes.game = {
    port = 25565;
    proto = "tcp";
    exposure = "public";
    auth = "native";
    via = [ "router" ];
  };

  # squaremap (survival), read-only web map on 127.0.0.1:8080. Public via
  # the edge at https://computerboyz.joshuabell.xyz/ (was /map/survival/).
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
