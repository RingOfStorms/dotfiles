# Zitadel SSO (sso.joshuabell.xyz) + its PostgreSQL 17, one container.
# Was hosts/h001/containers/zitadel.nix (private-network nixos container,
# 10.0.0.3:8080). Private network (net.private, 10.233.13.2): zitadel on
# :8085 behind host nginx, postgres on its unix socket only.
#
# Everyone (sec, life, open-webui, trilium, every sec-agent) logs in
# here, so a broken zitadel locks the fleet out of sec. Break-glass: the
# masterkey and pg dumps are in restic (persist below) and in the offline kit.
{
  name = "zitadel";
  kind = "nixos";
  description = "Zitadel SSO (sso.joshuabell.xyz)";
  host = "h001";

  persist = {
    # PG 17 cluster in ./17, copied 1:1 from /var/lib/zitadel/postgres.
    postgresql = "/var/lib/postgresql";
    pgdumps = "/var/backup/postgresql"; # nightly postgresqlBackup + backupHook dump
    # masterkey (32 bytes). Irreplaceable: without it the DB's encrypted
    # columns are unreadable. Lives in persist so it travels with moves and
    # backups. Not served by sec-agent on purpose (sec logs in via zitadel).
    keys = "/var/lib/zitadel-keys";
    nixos = "/var/lib/nixos";
  };

  backupHook = "set -o pipefail; runuser -u postgres -- pg_dumpall | gzip > /var/backup/postgresql/cnt-dumpall.sql.gz";

  # o002 terminates TLS and forwards plain http over the tailnet; the route
  # keeps the default forwardedProto = "https" so zitadel still believes it
  # is https. Public via edge (o002) since every login starts here.
  # Private network (ROUTING-PLAN §8 step 5). index is fleet-wide unique.
  net = {
    private = true;
    index = 13;
  };

  routes.web = {
    group = "Identity & Security";
    port = 8085;
    name = "sso";
    exposure = "public";
    auth = "native";
    # h001's http-level limit, which the old hand-written vhost inherited.
    maxBody = "500m";
  };
}
