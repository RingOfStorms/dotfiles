{
  constants,
  config,
  lib,
  inputs,
  ...
}:
let
  name = "zitadel";
  c = constants.services.zitadel;
  net = constants.containerNetwork;

  hostDataDir = c.dataDir;

  hostAddress = net.hostAddress;
  containerAddress = c.containerIp;
  hostAddress6 = net.hostAddress6;
  containerAddress6 = c.containerIp6;

  zitadelNixpkgs = inputs.zitadel-nixpkgs;

  hasSecret =
    secret:
    let
      secrets = config.age.secrets or { };
    in
    secrets ? ${secret} && secrets.${secret} != null;

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
  ]
  ++ lib.optionals (hasSecret "zitadel_master_key") [
    # secret
    {
      host = config.age.secrets.zitadel_master_key.path;
      container = "/var/secrets/zitadel_master_key.age";
      readOnly = true;
    }
  ];
  bindsWithUsers = lib.filter (b: b ? user) binds;
  uniqueUsers = lib.foldl' (
    acc: bind: if lib.lists.any (item: item.user == bind.user) acc then acc else acc ++ [ bind ]
  ) [ ] bindsWithUsers;
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
    services.nginx.virtualHosts."${c.domain}" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
      locations = {
        "/" = {
          proxyWebsockets = true;
          recommendedProxySettings = true;
          proxyPass = "http://${containerAddress}:${toString c.port}";
          extraConfig = ''
            proxy_set_header X-Forwarded-Proto https;
          '';
        };
      };
    };

    # Ensure users exist on host machine
    inherit users;

    # Ensure directories exist on host machine
    system.activationScripts."createDirsFor${name}" = ''
      ${lib.concatStringsSep "\n" (
        lib.map (bind: ''
          mkdir -p ${bind.host}
          chown ${toString bind.user}:${toString bind.gid} ${bind.host}
          chmod 750 ${bind.host}
        '') bindsWithUsers
      )}
    '';

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
            isReadOnly = bind.readOnly or false;
          };
        }
        // acc
      ) { } binds;
      nixpkgs = zitadelNixpkgs;
      config =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        {
          config = {
            system.stateVersion = "25.05";

            networking = {
              firewall = {
                enable = true;
                allowedTCPPorts = [
                  c.port
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
              masterKeyFile = "/var/secrets/zitadel_master_key.age";
              settings = {
                Port = c.port;
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
                ExternalDomain = c.domain;
                ExternalPort = 443;
                ExternalSecure = true;
              };
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
              openFirewall = true;
            };

            systemd.services.zitadel = {
              requires = [ "postgresql.service" ];
              after = [ "postgresql.service" ];
            };
          };
        };
    };
  };
}
