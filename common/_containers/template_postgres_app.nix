{ name }:
{
  config,
  lib,
  ...
}:
let
  # name = "UNIQUE_NAME_ON_HOST";

  hostDataDir = "/var/lib/${name}";
  hostAddress = "192.168.100.2";
  containerAddress = "192.168.100.10";

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
    # App data, uses custom user
    # {
    #   host = "${hostDataDir}/data";
    #   container = "/var/lib/forgejo";
    #   user = "forgejo";
    #   uid = 115;
    #   gid = 115;
    # }
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
  # Ensure users exists on host machine with same IDs as container
  inherit users;

  # Ensure directories exist on host machine
  system.activationScripts.createMediaServerDirs = ''
    ${lib.concatStringsSep "\n" (
      lib.map (bind: ''
        mkdir -p ${bind.host}
        chown -R ${toString bind.user}:${toString bind.gid} ${bind.host}
        chmod -R 750 ${bind.host}
      '') binds
    )}
  '';

  containers.${name} = {
    ephemeral = true;
    autoStart = true;
    privateNetwork = true;
    hostAddress = hostAddress;
    localAddress = containerAddress;
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

        # Ensure users exist on container
        inherit users;

        services.postgresql = {
          enable = true;
          package = pkgs.postgresql_17.withJIT;
          enableJIT = true;
          extensions = with pkgs.postgresql17Packages; [
            # NOTE add extensions here
            pgvector
            postgis
          ];
          enableTCPIP = true;
          authentication = ''
            local all all trust
            host all all 127.0.0.1/8 trust
            host all all ::1/128 trust
            host all all 192.168.100.0/24 trust
          '';
          # identMap = ''
          #   # ArbitraryMapName systemUser dbUser
          #   superuser_map      root       ${name}
          #
          #   # Let other names login as themselves
          #   superuser_map      /^(.*)$    \1
          # '';
          # ensureDatabases = [ name ];
          # ensureUsers = [
          #   {
          #     name = name;
          #     ensureDBOwnership = true;
          #     ensureClauses = {
          #       login = true;
          #       superuser = true;
          #     };
          #   }
          # ];
        };

        # Backup database
        services.postgresqlBackup = {
          enable = true;
        };

        # APP TODO REPLACE THIS WITH SOMETHING
        services.pgadmin = {
          enable = true;
          openFirewall = true;
          initialEmail = "admin@test.com";
          initialPasswordFile = (builtins.toFile "password" "password");
        };
      };
  };
}
