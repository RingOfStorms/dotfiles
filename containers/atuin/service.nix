{
  name = "atuin";
  kind = "nixos";
  description = "atuin shell-history sync server (atuin.joshuabell.xyz)";

  persist = {
    # PG 17 cluster in ./17 plus dumpall.sql from backupHook.
    postgresql = "/var/lib/postgresql";
    nixos = "/var/lib/nixos"; # uid/gid map, keeps file owners stable
  };

  # Consistent SQL dump that travels with backups/moves.
  backupHook = "runuser -u postgres -- pg_dumpall > /var/lib/postgresql/dumpall.sql";

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
