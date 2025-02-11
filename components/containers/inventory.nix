{
  config,
  lib,
  ...
}:

let
  name = "inventory";
  app = "pg-${name}";

  hostDataDir = "/var/lib/${name}";

  localAddress = "192.168.100.110";
  pg_port = 54433;
  pg_dataDir = "/var/lib/postgres";
  # pgadmin_port = 5050;
  # pgadmin_dataDir = "/var/lib/pgadmin";

  binds = [
    {
      host = "${hostDataDir}/postgres";
      container = pg_dataDir;
      user = "postgres";
      uid = config.ids.uids.postgres;
    }
    # {
    #   host = "${hostDataDir}/pgadmin";
    #   container = pgadmin_dataDir;
    #   user = "pgadmin";
    #   uid = 1020;
    # }
  ];
in
{

  users = lib.foldl (
    acc: bind:
    {
      users.${bind.user} = {
        isSystemUser = true;
        home = bind.host;
        createHome = true;
        uid = bind.uid;
        group = bind.user;
      };
      groups.${bind.user}.gid = bind.uid;
    }
    // acc
  ) { } binds;

  containers.${app} = {
    ephemeral = true;
    autoStart = true;
    privateNetwork = true;
    hostAddress = "192.168.100.2";
    localAddress = localAddress;
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
        system.stateVersion = "24.11";

        users = lib.foldl (
          acc: bind:
          {
            users.${bind.user} = {
              isSystemUser = true;
              home = bind.container;
              uid = bind.uid;
              group = bind.user;
            };
            groups.${bind.user}.gid = bind.uid;
          }
          // acc
        ) { } binds;

        services.postgresql = {
          enable = true;
          package = pkgs.postgresql_17.withJIT;
          enableJIT = true;
          extensions = with pkgs.postgresql17Packages; [
            # NOTE add extensions here
            pgvector
            postgis
          ];
          settings.port = pg_port;
          enableTCPIP = true;
          authentication = ''
            local all all trust
            host all all 127.0.0.1/8 trust
            host all all ::1/128 trust
            host all all 192.168.100.0/24 trust
          '';
          identMap = ''
            # ArbitraryMapName systemUser dbUser
            superuser_map      root       ${name}

            # Let other names login as themselves
            superuser_map      /^(.*)$    \1
          '';
          ensureDatabases = [ name ];
          ensureUsers = [
            {
              name = name;
              ensureDBOwnership = true;
              ensureClauses = {
                login = true;
                superuser = true;
              };
            }
          ];
          dataDir =
            (lib.findFirst (bind: bind.user == "postgres") (throw "No postgres bind found") binds).container;
        };

        # services.pgadmin = {
        #   enable = true;
        #   port = pgadmin_port;
        #   openFirewall = true;
        #   initialEmail = "admin@test.com";
        #   initialPasswordFile = (builtins.toFile "password" "password");
        # };

        # TODO set this up, had issues since it shares users with postgres service and my bind mounts relys on createhome in that exact directory.
        # services.postgresqlBackup = {
        #   enable = true;
        #   compression = "gzip";
        #   compressionLevel = 9;
        #   databases = [ cfg.database ];
        #   location = "${cfg.dataDir}/backup";
        #   startAt = "02:30"; # Adjust the backup time as needed
        # };

        networking.firewall = {
          enable = true;
          allowedTCPPorts = [ pg_port ];
        };

        # Health check to ensure database is ready
        systemd.services.postgresql-healthcheck = {
          description = "PostgreSQL Health Check";
          after = [ "postgresql.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = ''
              ${pkgs.postgresql_17}/bin/pg_isready \
                -U ${name} \
                -d ${name} \
                -h localhost \
                -p ${toString pg_port}
            '';
          };
        };
      };
  };
}
