# Guest config. zitadel on :8085, postgres on its unix socket only. Zitadel has no
# bind-address setting; it listens on all interfaces. With net.private that
# is the guest netns, whose firewall admits 8085 from the host only.
{ pkgs, lib, ... }:
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
    # Only used on an empty database (first boot); an existing DB already has it.
    steps.FirstInstance = {
      InstanceName = "sso";
      Org = {
        Name = "SSO";
        Human = {
          UserName = "admin@joshuabell.xyz";
          FirstName = "admin";
          LastName = "admin";
          Email.Address = "admin@joshuabell.xyz";
          Email.Verified = true;
          Password = "Password1!";
          PasswordChangeRequired = true;
        };
      };
      LoginPolicy.AllowRegister = false;
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
  };
}
