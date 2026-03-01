{
  constants,
  config,
  lib,
  inputs,
  ...
}:
let
  name = "dawarich";
  c = constants.services.dawarich;
  net = constants.containerNetwork;

  # Data stored on the wd10 drive as requested
  hostDataDir = c.dataDir;

  hostAddress = net.hostAddress;
  containerAddress = c.containerIp;
  hostAddress6 = net.hostAddress6;
  containerAddress6 = c.containerIp6;

  dawarichNixpkgs = inputs.dawarich-nixpkgs;

  domain = c.domain;
  webPort = c.port;

  binds = [
    # Postgres data, must use postgres user in container and host
    {
      host = "${hostDataDir}/postgres";
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
    # Redis data
    {
      host = "${hostDataDir}/redis";
      container = "/var/lib/redis-dawarich";
      user = "redis-dawarich";
      uid = c.redisUid;
      gid = c.redisGid;
    }
    # Dawarich app data (uploads, cache, etc.)
    {
      host = "${hostDataDir}/data";
      container = "/var/lib/dawarich";
      user = "dawarich";
      uid = c.uid;
      gid = c.gid;
    }
    # Secret key base file - must match the path the dawarich module expects
    # The module uses systemd LoadCredential from /var/lib/dawarich/secrets/secret-key-base
    {
      host = "${hostDataDir}/secrets/secret-key-base";
      container = "/var/lib/dawarich/secrets/secret-key-base";
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

  # Secret file path (if using secrets)
  hasSecret =
    secret:
    let
      secrets = config.age.secrets or { };
    in
    secrets ? ${secret} && secrets.${secret} != null;
in
{
  options = { };

  config = {
    services.nginx.virtualHosts."${domain}" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
      extraConfig = ''
        client_max_body_size 50G;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        send_timeout 600s;
      '';
      locations = {
        "/" = {
          proxyWebsockets = true;
          recommendedProxySettings = true;
          proxyPass = "http://${containerAddress}:${toString webPort}";
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
      # Create secrets directory (for manual secret key base setup)
      mkdir -p ${hostDataDir}/secrets
      chmod 700 ${hostDataDir}/secrets
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
      nixpkgs = dawarichNixpkgs;
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
                allowedTCPPorts = [ webPort ];
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
              # Dawarich requires PostGIS for geospatial features
              package = pkgs.postgresql_17.withPackages (p: [ p.postgis ]);
              enableJIT = true;
              extensions = ps: [ ps.postgis ];
              authentication = ''
                local all all trust
                host all all 127.0.0.1/8 trust
                host all all ::1/128 trust
                host all all fc00::1/128 trust
              '';
              ensureDatabases = [ "dawarich" ];
              # Pre-create postgis extension as superuser (dawarich user can't create extensions)
              initialScript = pkgs.writeText "dawarich-pg-init.sql" ''
                \connect dawarich
                CREATE EXTENSION IF NOT EXISTS postgis;
              '';
              ensureUsers = [
                {
                  name = "dawarich";
                  ensureDBOwnership = true;
                  ensureClauses.login = true;
                }
              ];
            };

            # Backup database
            services.postgresqlBackup = {
              enable = true;
            };

            services.dawarich = {
              enable = true;
              webPort = webPort;
              localDomain = domain;

              # Database configuration (using local postgres)
              database = {
                createLocally = false; # We create it via ensureDatabases
                host = "/var/run/postgresql";
                name = "dawarich";
                user = "dawarich";
                # passwordFile not needed with socket auth
              };

              # Redis configuration
              redis = {
                createLocally = true;
              };

              # Secret key base - path must match what the module expects
              # The secret file is bind-mounted to /var/lib/dawarich/secrets/secret-key-base
              secretKeyBaseFile = "/var/lib/dawarich/secrets/secret-key-base";

              # Enable automatic migrations
              automaticMigrations = true;

              # Sidekiq configuration for background jobs
              sidekiqThreads = 5;

              # Environment variables for additional configuration
              environment = {
                # Enable registration for initial setup (set to "true" to disable after creating accounts)
                DISABLE_REGISTRATION = "false";
                # Set timezone if needed
                # TIME_ZONE = "America/Chicago";
              };
            };

            # Ensure postgis extension exists before dawarich-init-db runs
            # (initialScript only runs on first cluster creation)
            systemd.services.dawarich-postgis-init = {
              description = "Initialize PostGIS extension for Dawarich";
              requires = [ "postgresql.service" ];
              after = [ "postgresql.service" ];
              before = [ "dawarich-init-db.service" ];
              requiredBy = [ "dawarich-init-db.service" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                User = "postgres";
                Group = "postgres";
                ExecStart = pkgs.writeShellScript "dawarich-postgis-init" ''
                  ${config.services.postgresql.package}/bin/psql -d dawarich -c "CREATE EXTENSION IF NOT EXISTS postgis;"
                '';
              };
            };
          };
        };
    };
  };
}
