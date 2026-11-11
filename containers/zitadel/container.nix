# Guest config. zitadel on :8085, postgres on its unix socket only. Zitadel has no
# bind-address setting; it listens on all interfaces. With net.private that
# is the guest netns, whose firewall admits 8085 from the host only.
{ config, pkgs, lib, zitadelPackage, ... }:
let
  cfg = config.services.zitadel;
  settingsFormat = pkgs.formats.yaml { };
  configFile = settingsFormat.generate "zitadel-config.yaml" cfg.settings;
  args = lib.cli.toCommandLineShellGNU { } {
    config = cfg.extraSettingsPaths ++ [ configFile ];
    masterkeyFile = cfg.masterKeyFile;
    inherit (cfg) tlsMode;
  };
in
{
  system.stateVersion = "25.05";

  # postgres is 71 by default (config.ids), matching the persisted cluster.

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17.withJIT;
    enableJIT = true;
    dataDir = "/var/lib/postgresql/17";
    settings.listen_addresses = lib.mkForce "";
    authentication = lib.mkForce ''
      local all all trust
    '';
    ensureDatabases = [ "zitadel" ];
    ensureUsers = [
      {
        name = "zitadel";
        ensureDBOwnership = true;
        ensureClauses.login = true;
        ensureClauses.superuser = true;
      }
    ];
  };
  services.postgresqlBackup.enable = true;

  services.zitadel = {
    enable = true;
    package = zitadelPackage;
    # Masterkey is 0400 owned by zitadel:zitadel (tmpfiles rule below):
    # only the zitadel service user can read it inside the container, not
    # every other process sharing the container's root.
    masterKeyFile = "/var/lib/zitadel-keys/masterkey";

    settings = {
      Port = 8085;
      Database.postgres = {
        Host = "/run/postgresql/";
        Port = 5432;
        Database = "zitadel";
        User = {
          Username = "zitadel";
          SSL.Mode = "disable";
        };
        Admin = {
          Username = "zitadel";
          SSL.Mode = "disable";
          ExistingDatabase = "zitadel";
        };
      };
      ExternalDomain = "sso.joshuabell.xyz";
      ExternalPort = 443;
      ExternalSecure = true;
    };
  };

  # Masterkey must be 0400 zitadel:zitadel. tmpfiles runs as root before the
  # zitadel service starts, so this re-asserts ownership/mode on every
  # boot even if the file was restored from backup with different perms.
  systemd.tmpfiles.rules = [
    "z /var/lib/zitadel-keys/masterkey 0400 zitadel zitadel - -"
  ];

  systemd.services.zitadel = {
    requires = [ "postgresql.service" ];
    after = [ "postgresql.service" ];
    # Restore the existing database before starting: this is not a new-instance
    # bootstrap. Keep Login V1; adopting the separate Login V2 app is not part
    # of this upgrade. setup must succeed before the server can start.
    script = lib.mkForce ''
      zitadel setup ${args} --init-projections=true
      exec zitadel start ${args}
    '';
  };
}
