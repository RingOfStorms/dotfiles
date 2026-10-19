# Forgejo (git.joshuabell.xyz) + its PostgreSQL 17, one container.
# Was hosts/h001/containers/forgejo.nix (private-network nixos container,
# 10.0.0.2). Host network now: HTTP on 127.0.0.1:3000 behind nginx (routes.web),
# builtin SSH directly on 0.0.0.0:3032 (routes.ssh; o002 streams public :3032
# here over the tailnet; replaces the old h001 nginx stream).
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

  routes.web = {
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
