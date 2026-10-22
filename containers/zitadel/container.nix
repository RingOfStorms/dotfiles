# Guest config: services.zitadel copied from hosts/h001/containers/zitadel.nix.
# zitadel on :8085, postgres on its unix socket only. Zitadel has no
# bind-address setting; it listens on all interfaces. With net.private that
# is the guest netns, whose firewall admits 8085 from the host only.
{ pkgs, lib, ... }:
{
  system.stateVersion = "25.05";

  # postgres is 71 by default (config.ids), matching the copied cluster.

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
    # zitadel reads this path directly as its own user: keep the file 0444
    # (as on h001 today) or chown it to the guest zitadel user.
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
    # Only used on an empty database (first boot); the copied DB already has it.
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

  systemd.services.zitadel = {
    requires = [ "postgresql.service" ];
    after = [ "postgresql.service" ];
  };
}
