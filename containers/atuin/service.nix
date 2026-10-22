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

  # atuin listens on :8888 in its private netns; only host nginx reaches it.
  # o002 terminates TLS for the public name and proxies to h001:80 over the
  # tailnet; tailnet clients may hit h001:443 directly (wildcard cert).
  # Private network (ROUTING-PLAN §8 step 5): guest 10.233.3.2.
  net = {
    private = true;
    index = 3;
  };

  routes.web = {
    group = "Personal";
    icon = "https://api.iconify.design/mdi/console.svg?color=%237ee787";
    port = 8888;
    exposure = "public";
    auth = "native";
    maxBody = "64m";
  };
}
