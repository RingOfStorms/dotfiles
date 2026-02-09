{
  config,
  lib,
  inputs,
  ...
}:
let
  name = "dawarich";

  # Data stored on the wd10 drive as requested
  hostDataDir = "/drives/wd10/${name}";

  hostAddress = "10.0.0.1";
  containerAddress = "10.0.0.4";
  hostAddress6 = "fc00::1";
  containerAddress6 = "fc00::4";

  dawarichNixpkgs = inputs.dawarich-nixpkgs;

  domain = "location.joshuabell.xyz";
  webPort = 3001;

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
      uid = 976;
      gid = 976;
    }
    # Dawarich app data (uploads, cache, etc.)
    {
      host = "${hostDataDir}/data";
      container = "/var/lib/dawarich";
      user = "dawarich";
      uid = 977;
      gid = 977;
    }
    # Secret key base file - manual setup
    {
      host = "${hostDataDir}/secrets/secret_key_base";
      container = "/var/secrets/secret_key_base";
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
    services.nginx.virtualHosts."${domain}" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
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
          chown -R ${toString bind.user}:${toString bind.gid} ${bind.host}
          chmod -R 750 ${bind.host}
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
              package = pkgs.postgresql_17.withJIT;
              enableJIT = true;
              authentication = ''
                local all all trust
                host all all 127.0.0.1/8 trust
                host all all ::1/128 trust
                host all all fc00::1/128 trust
              '';
              ensureDatabases = [ "dawarich" ];
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

              # Secret key base - create this file manually:
              # Generate with: openssl rand -hex 64 > /drives/wd10/dawarich/secrets/secret_key_base
              # Then update bind mount above to include it
              # secretKeyBaseFile = "/var/secrets/secret_key_base";

              # Enable automatic migrations
              automaticMigrations = true;

              # Sidekiq configuration for background jobs
              sidekiqThreads = 5;

              # Environment variables for additional configuration
              environment = {
                # Set timezone if needed
                # TIME_ZONE = "America/Chicago";
              };
            };

            systemd.services.dawarich = {
              requires = [
                "postgresql.service"
                "redis-dawarich.service"
              ];
              after = [
                "postgresql.service"
                "redis-dawarich.service"
              ];
            };
          };
        };
    };
  };
}
