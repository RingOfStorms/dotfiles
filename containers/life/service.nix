# Life server (life.joshuabell.xyz): Rust server + PostgreSQL 18 +
# pgBackRest + nightly restic, in one private-network container (guest :8080).
#
# APK releases: publish to /srv/containers/life/state/releases on the host
# running life.
{
  name = "life";
  kind = "nixos";
  description = "Life server (life.joshuabell.xyz)";

  persist = {
    state = "/var/lib/life"; # blobs, releases, nightly logical backups
    postgres = "/var/lib/postgresql/18";
    pgbackrest = "/var/lib/pgbackrest"; # local encrypted repo1
    nixos = "/var/lib/nixos";
  };

  # Logical dump that travels with cnt backups/moves (pgBackRest repo too).
  backupHook = "mkdir -p /var/lib/life/backups && runuser -u postgres -- pg_dumpall > /var/lib/life/backups/cnt-dumpall.sql";

  # Life validates Zitadel tokens (issuer sso.joshuabell.xyz) through the host
  # nginx and calls LocalAI (recognition, localai.joshuabell.xyz) on joe's
  # nginx; restic/pgBackRest offsite targets are on the internet.
  net = {
    private = true;
    index = 17;
    uses = [
      "zitadel.web"
      "localai.web"
    ];
  };

  # Client IP: public traffic is client -> o002 nginx -> (tailnet) here; the
  # generated edge listener trusts X-Forwarded-For from o002 only, and Life
  # takes the last entry.
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
    extraConfig = ''
      proxy_set_header X-Forwarded-Host $host;
    '';
  };
}
