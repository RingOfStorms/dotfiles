# Guest config (net.private, 10.233.15.2): immich-server on
# fleetNet.bindAddress:2283, ML on *:3003, postgres on its unix socket +
# *:5432, redis on a unix socket.
# uids pinned to the copied data (immich 916; postgres is 71 by default).
#
# Tailnet access for immich_manager (~/projects/immich_manager):
#   - postgres TCP: only role immich_ro (read-only, scram password) from
#     100.64.0.0/10 or loopback; everything else is socket-only via pg_hba.
#   - ML :3003 is unauthenticated; reachable on the tailnet only.
#   Both are tailnet routes with allow = [ "lio" ] (service.nix): the host
#   DNATs them only for its overlay IP and only from lio. DNAT keeps the
#   source address, so pg_hba still sees 100.64.0.1.
{
  config,
  pkgs,
  lib,
  fleetNet,
  ...
}:
{
  system.stateVersion = "25.05";

  users.users.immich.uid = 916;
  users.groups.immich.gid = 916;

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;
    enableJIT = true;
    dataDir = "/var/lib/postgresql/16";
    # Port stays 5432 so immich's socket URL and pg_dumpall need no changes.
    # Nothing else on h001 binds TCP 5432 (other containers are socket-only).
    settings.listen_addresses = lib.mkForce "*";
    authentication = lib.mkForce ''
      local all all trust
      host immich immich_ro 100.64.0.0/10 scram-sha-256
      host immich immich_ro 127.0.0.1/32 scram-sha-256
      host immich immich_ro ::1/128 scram-sha-256
    '';
    ensureDatabases = [ "immich" ];
    ensureUsers = [
      {
        name = "immich";
        ensureDBOwnership = true;
        ensureClauses.login = true;
      }
    ];
  };
  services.postgresqlBackup.enable = true;

  # Read-only role for immich_manager. Password generated on first start and
  # kept in the `dbro` persist dir (host: /srv/containers/immich/dbro/password).
  systemd.services.immich-ro-role = {
    description = "Ensure read-only postgres role immich_ro";
    requires = [ "postgresql-setup.service" ];
    after = [ "postgresql-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      config.services.postgresql.package
      pkgs.coreutils
      pkgs.util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      pw=/var/lib/immich-dbro/password
      if [ ! -s "$pw" ]; then
        umask 077
        head -c 33 /dev/urandom | base64 | tr -d '/+=\n' > "$pw"
      fi
      runuser -u postgres -- psql -d immich -v ON_ERROR_STOP=1 -v pw="$(cat "$pw")" <<'EOF'
      SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'immich_ro') AS missing \gset
      \if :missing
        CREATE ROLE immich_ro LOGIN;
      \endif
      ALTER ROLE immich_ro WITH LOGIN PASSWORD :'pw';
      ALTER ROLE immich_ro SET default_transaction_read_only = on;
      GRANT pg_read_all_data TO immich_ro;
      EOF
    '';
  };

  # The immich module adds pgvector + vectorchord and the vchord preload
  # itself when database.enable = true; don't override.

  services.immich = {
    enable = true;
    host = fleetNet.bindAddress;
    port = 2283;
    mediaLocation = "/var/lib/immich";
    database = {
      enable = true;
      createDB = false; # ensureDatabases above
      name = "immich";
      user = "immich";
    };
    redis.enable = true; # unix socket
    machine-learning.enable = true;
    # Module hardcodes localhost; open it for immich_manager (routes.ml).
    machine-learning.environment.IMMICH_HOST = lib.mkForce "0.0.0.0";
    settings = {
      server.externalDomain = "https://photos.joshuabell.xyz";
      newVersionCheck.enabled = false;
    };
  };
  systemd.services.immich-server = {
    requires = [ "postgresql.service" ];
    after = [ "postgresql.service" ];
  };
}
