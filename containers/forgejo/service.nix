# Forgejo (git.joshuabell.xyz) + its PostgreSQL 17, one container.
# Private network (net.private, 10.233.11.2): HTTP :3000 behind host nginx
# (routes.web), builtin SSH :3032 DNATed from the host port (routes.ssh; o002
# streams public :3032 to h001 over the tailnet).
{
  name = "forgejo";
  kind = "nixos";
  description = "Forgejo git forge (git.joshuabell.xyz, ssh :3032)";
  host = "h001";

  persist = {
    data = "/var/lib/forgejo"; # repositories, custom/conf/app.ini + secrets, lfs, avatars
    postgres = "/var/lib/postgresql/17";
    pgdumps = "/var/backup/postgresql"; # nightly postgresqlBackup
    nixos = "/var/lib/nixos";
  };

  backupHook = "runuser -u postgres -- pg_dumpall > /var/backup/postgresql/cnt-dumpall.sql";

  # Private network (ROUTING-PLAN §8 step 5). index is fleet-wide unique.
  net = {
    private = true;
    index = 11;
  };

  routes.web = {

    group = "Productivity";
    port = 3000;
    name = "git";
    exposure = "public";
    auth = "native";
    maxBody = "1g";
    timeouts = "600s";
  };
  # Builtin SSH must face the network: o002 streams public :3032 here over
  # the tailnet, and tailnet clients use it directly.
  routes.ssh = {
    port = 3032;
    proto = "tcp";
    exposure = "public";
    auth = "native";
    via = [ "edge" ];
  };
}
