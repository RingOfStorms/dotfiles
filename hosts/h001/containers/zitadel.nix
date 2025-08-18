{
  config,
  lib,
  ...
}:
let
  name = "zitadel";

  hostDataDir = "/var/lib/${name}";

  hostAddress = "10.0.0.1";
  containerAddress = "10.0.0.3";
  hostAddress6 = "fc00::1";
  containerAddress6 = "fc00::3";

  binds = [
    # Postgres data, must use postgres user in container and host
    {
      host = "${hostDataDir}/postgres";
      # Adjust based on container postgres data dir
      container = "/var/lib/postgresql/17";
      user = "postgres";
      uid = config.ids.uids.postgres;
      gid = config.ids.gids.postgres;
    }
    # Postgres backups
    {
      host = "${hostDataDir}/backups/postgres";
      container = "/var/backup/postgresql";
      user = "postgres";
      uid = config.ids.uids.postgres;
      gid = config.ids.gids.postgres;
    }
  ];
  uniqueUsers = lib.foldl' (
    acc: bind: if lib.lists.any (item: item.user == bind.user) acc then acc else acc ++ [ bind ]
  ) [ ] binds;
  users = {
    users = lib.listToAttrs (
      lib.map (u: {
        name = u.user;
        value = {
          isSystemUser = true;
          name = u.user;
          uid = u.uid;
          group = u.user;
        };
      }) uniqueUsers
    );

    groups = lib.listToAttrs (
      lib.map (g: {
        name = g.user;
        value.gid = g.gid;
      }) uniqueUsers
    );
  };

in
{
  options = { };
  config = {
    services.nginx.virtualHosts."sso.joshuabell.xyz" = {
      locations = {
        "/" = {
          proxyWebsockets = true;
          proxyPass = "http://${containerAddress}:8080";
        };
      };
    };

    containers.${name} = {
      ephemeral = true;
      autoStart = true;
      privateNetwork = true;
      hostAddress = hostAddress;
      localAddress = containerAddress;
      hostAddress6 = hostAddress6;
      localAddress6 = containerAddress6;
      bindMounts = lib.foldl (
        acc: bind:
        {
          "${bind.container}" = {
            hostPath = bind.host;
            isReadOnly = false;
          };
        }
        // acc
      ) { } binds;
      config =
        { config, pkgs, ... }:
        {
          system.stateVersion = "25.05";

          networking = {
            firewall = {
              enable = true;
              allowedTCPPorts = [
                3000
                3032
              ];
            };
            # Use systemd-resolved inside the container
            # Workaround for bug https://github.com/NixOS/nixpkgs/issues/162686
            useHostResolvConf = lib.mkForce false;
          };
          services.resolved.enable = true;

          # Ensure users exist on container
          inherit users;

          services.postgresql = {
            enable = true;
            package = pkgs.postgresql_17.withJIT;
            enableJIT = true;
            authentication = ''
              local all all trust
              host all all 127.0.0.1/8 trust
              host all all ::1/128 trust
              host all all fc00::1/128 trust
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

          # Backup database
          services.postgresqlBackup = {
            enable = true;
          };

          services.zitadel = {
            enable = true;
            # masterKeyFile = "TODO";
            settings = {
              Port = 8080;
              Database.postgres = {
                Host = "/var/run/postgresql/";
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
            steps.FirstInstance = {
              InstanceName = "ros_sso";
              Org = {
                Name = "ZI";
                Human = {
                  UserName = "admin@joshuabell.xyz";
                  FirstName = "admin";
                  LastName = "admin";
                  Email.Address = "admin@joshuabell.xuz";
                  Email.Verified = true;
                  Password = "Password1!";
                  PasswordChangeRequired = true;
                };
              };
              LoginPolicy.AllowRegister = false;
            };
            openFirewall = true;
          };

          systemd.services.zitadel = {
            requires = [ "postgresql.service" ];
            after = [ "postgresql.service" ];
          };
        };
    };
  };
}
