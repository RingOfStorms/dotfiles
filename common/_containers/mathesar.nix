{
  config,
  pkgs,
  ...
}:
let
  cfg = config.services.mathesar;
in
{
  options.services.mathesar =
    let
      lib = pkgs.lib;
    in
    {
      port = lib.mkOption {
        type = lib.types.port;
        default = 3081;
        description = "Port number for the Mathesar";
      };
      dataDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/mathesar";
        description = "Directory to store Mathesar data";
      };
      secretKey = lib.mkOption {
        type = lib.types.str;
        # echo $(cat /dev/urandom | LC_CTYPE=C tr -dc 'a-zA-Z0-9' | head -c 50)
        # https://docs.djangoproject.com/en/4.2/ref/settings/#secret-key
        description = "Secret key for Django security features";
      };
      domainName = lib.mkOption {
        type = lib.types.str;
        default = "http://10.20.40.104";
        description = "Custom domain(s) for accessing Mathesar";
      };
      postgresDb = lib.mkOption {
        type = lib.types.str;
        default = "mathesar_django";
        description = "Database name for Mathesar";
      };
      postgresUser = lib.mkOption {
        type = lib.types.str;
        default = "mathesar";
        description = "Database user for Mathesar";
      };
      postgresPassword = lib.mkOption {
        type = lib.types.str;
        default = "mathesar";
        description = "Database password for Mathesar";
      };
      postgresHost = lib.mkOption {
        type = lib.types.str;
        default = "mathesar_db";
        description = "Host running the PostgreSQL database";
      };
      postgresPort = lib.mkOption {
        type = lib.types.port;
        default = 3082;
        description = "Port on which PostgreSQL is running";
      };
      allowedHosts = lib.mkOption {
        type = lib.types.str;
        default = "*";
        description = "Allowed hosts for Mathesar web service. ";
      };
    };

  config = {
    systemd.services.create-mathesar-network = {
      description = "Create Docker network for Mathesar";
      serviceConfig.Type = "oneshot";
      wantedBy = [ "multi-user.target" ];
      script = ''
        if ! ${pkgs.docker}/bin/docker network inspect mathesar_network >/dev/null 2>&1; then
          ${pkgs.docker}/bin/docker network create mathesar_network
        fi
      '';
    };

    virtualisation.oci-containers.containers = {
      ################
      # mathesar_service
      ################
      mathesar_service = {
        user = "root";
        image = "mathesar/mathesar:latest";
        dependsOn = [ "mathesar_db" ];
        environment = {
          SECRET_KEY = cfg.secretKey;
          DOMAIN_NAME = cfg.domainName;
          POSTGRES_DB = cfg.postgresDb;
          POSTGRES_USER = cfg.postgresUser;
          POSTGRES_PASSWORD = cfg.postgresPassword;
          POSTGRES_HOST = cfg.postgresHost;
          POSTGRES_PORT = (toString cfg.postgresPort);
          DJANGO_SETTINGS_MODULE = "config.settings.production";
          # Allowed hosts is * to allow all traffic on service.
          # The caddy proxy handles the rest.
          ALLOWED_HOSTS = "*";
        };
        volumes = [
          "${cfg.dataDir}/static:/code/static"
          "${cfg.dataDir}/media:/code/media"
        ];
        extraOptions = [
          "--network=mathesar_network"
          "--expose=8000"
        ];
      };

      ################
      # mathesar_db (PostgreSQL Database)
      ################
      mathesar_db = {
        user = "root";
        image = "postgres:13";
        environment = {
          POSTGRES_DB = cfg.postgresDb;
          POSTGRES_USER = cfg.postgresUser;
          POSTGRES_PASSWORD = cfg.postgresPassword;
          PGPORT = toString cfg.postgresPort;
        };
        volumes = [
          "${cfg.dataDir}/pgdata:/var/lib/postgresql/data"
        ];
        extraOptions = [
          "--network=mathesar_network"
          "--expose=${toString cfg.postgresPort}"
        ];
      };

      ##############
      # caddy-reverse-proxy
      ##############
      caddy_reverse_proxy = {
        user = "root";
        image = "mathesar/mathesar-caddy:latest";
        ports = [
          "10.20.40.104:${toString cfg.port}:80"
        ];
        environment = {
          SECRET_KEY = cfg.secretKey;
          DOMAIN_NAME = cfg.domainName;
          POSTGRES_DB = cfg.postgresDb;
          POSTGRES_USER = cfg.postgresUser;
          POSTGRES_PASSWORD = cfg.postgresPassword;
          POSTGRES_HOST = cfg.postgresHost;
          POSTGRES_PORT = toString cfg.postgresPort;
        };
        volumes = [
          "${cfg.dataDir}/media:/code/media"
          "${cfg.dataDir}/static:/code/static"
          "${cfg.dataDir}/caddy:/data"
        ];
        extraOptions = [ "--network=mathesar_network" ];
      };
    };
  };
}
