# Guest config. Private network: paperless on :28981, tika on
# 127.0.0.1:9998 (guest loopback), gotenberg moved to 127.0.0.1:3002 (3000 is forgejo's),
# postgres and redis on unix sockets. uids pinned to the copied data
# (paperless 915; postgres is 71 by default).
{
  pkgs,
  lib,
  fleetNet,
  ...
}:
{
  system.stateVersion = "25.05";

  users.users.paperless.uid = lib.mkForce 915;
  users.groups.paperless.gid = lib.mkForce 915;

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;
    enableJIT = true;
    dataDir = "/var/lib/postgresql/16";
    # unix socket only.
    settings.listen_addresses = lib.mkForce "";
    authentication = lib.mkForce ''
      local all all trust
    '';
    ensureDatabases = [ "paperless" ];
    ensureUsers = [
      {
        name = "paperless";
        ensureDBOwnership = true;
        ensureClauses.login = true;
      }
    ];
  };
  services.postgresqlBackup.enable = true;

  services.gotenberg.port = 3002;

  services.paperless = {
    enable = true;
    address = fleetNet.bindAddress;
    port = 28981;
    dataDir = "/var/lib/paperless";
    mediaDir = "/var/lib/paperless/media";
    consumptionDir = "/var/lib/paperless/consume";
    database.createLocally = false; # ensureDatabases above
    configureTika = true;
    settings = {
      PAPERLESS_URL = "https://docs.joshuabell.xyz";
      PAPERLESS_DBENGINE = "postgresql";
      PAPERLESS_DBHOST = "/run/postgresql";
      PAPERLESS_DBNAME = "paperless";
      PAPERLESS_DBUSER = "paperless";
      PAPERLESS_OCR_LANGUAGE = "eng";
      PAPERLESS_CONSUMER_RECURSIVE = true;
      PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS = true;
      PAPERLESS_TIKA_ENDPOINT = "http://127.0.0.1:9998";
      PAPERLESS_TIKA_GOTENBERG_ENDPOINT = "http://127.0.0.1:3002";
    };
  };
  systemd.services.paperless-scheduler = {
    requires = [ "postgresql.service" ];
    after = [ "postgresql.service" ];
  };
}
