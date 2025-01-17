{
  config,
  pkgs,
  ...
}:
let
  cfg = config.services.affine;
in
{
  options.services.affine =
    let
      lib = pkgs.lib;
    in
    {
      port = lib.mkOption {
        type = lib.types.port;
        default = 3010;
        description = "Port number for the AFFiNE service";
      };
      dataDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/affine";
        description = "Directory to store AFFiNE data";
      };
    };

  config = {
    systemd.services.create-affine-network = {
      description = "Create Docker network for LibreChat";
      serviceConfig.Type = "oneshot";
      wantedBy = [ "multi-user.target" ];
      script = ''
        if ! ${pkgs.docker}/bin/docker network inspect affine-network >/dev/null 2>&1; then
          ${pkgs.docker}/bin/docker network create affine-network
        fi
      '';
    };

    virtualisation.oci-containers.containers = {
      #############
      # AFFiNE #
      #############
      # NOTE settings live in `/var/lib/librechat` manually right now
      # Note to remove limits from user need to mark user as subscriber in the database manually
      # docker exec it affine_postgres psql -U affine
      # select id, feature, configs from features;
      # select * from users;
      # select * from user_features;
      # feature_id = YOUR FEATURE ID YOU WANT TO ASSIGN (get it from 'List possible feature id's')
      # user_id = YOUR USER ID YOU WANT TO CHANGE (get it from 'List users with id's')
      # update user_features set feature_id = 35 where user_id = 'xxxxxx-xxxx-xxxxxxx-xxxx-xxxxxxxxxxxx';
      affine = {
        user = "root";
        image = "ghcr.io/toeverything/affine-graphql:stable";
        ports = [
          "10.20.40.104:${toString cfg.port}:${toString cfg.port}"
        ];
        dependsOn = [
          "affine_redis"
          "affine_postgres"
          "affine_migration"
        ];
        environment = {
          REDIS_SERVER_HOST = "affine_redis";
          DATABASE_URL = "postgresql://affine:password@affine_postgres:5432/affine";
        };
        volumes = [
          "${cfg.dataDir}/storage:/root/.affine/storage"
          "${cfg.dataDir}/config:/root/.affine/config"
        ];
        extraOptions = [
          "--network=affine-network"
        ];
      };

      affine_migration = {
        user = "root";
        image = "ghcr.io/toeverything/affine-graphql:stable";
        dependsOn = [
          "affine_redis"
          "affine_postgres"
        ];
        volumes = [
          "${cfg.dataDir}/storage:/root/.affine/storage"
          "${cfg.dataDir}/config:/root/.affine/config"
        ];
        environment = {
          REDIS_SERVER_HOST = "affine_redis";
          DATABASE_URL = "postgresql://affine:password@affine_postgres:5432/affine";
        };
        cmd = [
          "sh"
          "-c"
          "node ./scripts/self-host-predeploy.js"
        ];
        extraOptions = [ "--network=affine-network" ];
      };

      affine_redis = {
        user = "root";
        image = "redis";
        extraOptions = [
          "--network=affine-network"
          "--health-cmd=\"CMD-SHELL redis-cli ping\""
          "--health-interval=30s"
          "--health-timeout=10s"
          "--health-retries=3"
          "--health-start-period=30s"
        ];
      };

      affine_postgres = {
        user = "root";
        image = "postgres:16";
        environment = {
          POSTGRES_USER = "affine";
          POSTGRES_PASSWORD = "password";
          POSTGRES_DB = "affine";
          POSTGRES_INITDB_ARGS = "--data-checksums";
        };
        volumes = [
          "${cfg.dataDir}/postgres:/var/lib/postgresql/data"
        ];
        extraOptions = [
          "--network=affine-network"
          "--health-cmd=\"CMD-SHELL pg_isready -U affine\""
          "--health-interval=10s"
          "--health-timeout=5s"
          "--health-retries=5"
          "--health-start-period=30s"
        ];
      };
    };
  };
}
