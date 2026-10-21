# Life server (life.joshuabell.xyz): Rust server + PostgreSQL 18 +
# pgBackRest + nightly restic, in one container on 127.0.0.1:8080.
# Was hosts/h001/containers/life.nix (private-network nixos container).
#
# APK releases: publish to root@h001:/srv/containers/life/state/releases
# (was /var/lib/life/state/releases).
{
  name = "life";
  kind = "nixos";
  description = "Life server (life.joshuabell.xyz)";
  host = "h001";

  persist = {
    state = "/var/lib/life"; # blobs, releases, nightly logical backups
    postgres = "/var/lib/postgresql/18";
    pgbackrest = "/var/lib/pgbackrest"; # local encrypted repo1
    nixos = "/var/lib/nixos";
  };

  # Logical dump that travels with cnt backups/moves (pgBackRest repo too).
  backupHook = "mkdir -p /var/lib/life/backups && runuser -u postgres -- pg_dumpall > /var/lib/life/backups/cnt-dumpall.sql";

  # Client IP: public traffic is client -> o002 nginx -> (tailnet) here; trust
  # only o002 (100.64.0.5) for X-Forwarded-For, Life takes the last entry.
  # Blob uploads up to 100 MiB, streamed; long downloads / live sync.
  routes.web = {
    group = "Personal";
    icon = "https://api.iconify.design/game-icons/bonsai-tree.svg?color=%2386c88f";
    port = 8080;
    exposure = "public";
    auth = "native";
    maxBody = "110m";
    timeouts = "1h";
    requestBuffering = false;
    # Client IP: the generated edge listener trusts X-Forwarded-For from o002
    # only (ROUTING-PLAN §2.3); Life takes the last X-Forwarded-For entry.
    extraConfig = ''
      proxy_set_header X-Forwarded-Host $host;
    '';
  };
}
