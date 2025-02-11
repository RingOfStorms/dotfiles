{
  config,
  pkgs,
  ...
}:
let
  cfg = config.customServices.pgadmin;
in
{
  options.customServices.pgadmin =
    let
      lib = pkgs.lib;
    in
    {
      port = lib.mkOption {
        type = lib.types.port;
        default = 3085;
        description = "Port number for the PGAdmin interface";
      };
      dataDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/pgadmin";
        description = "Directory to store PGAdmin data";
      };
    };

  config = {
    virtualisation.oci-containers.containers = {
      #############
      # pgadmin #
      #############
      # NOTE settings live in `/var/lib/librechat` manually right now
      pgadmin = {
        user = "root";
        image = "dpage/pgadmin4:latest";
        ports = [
          "10.20.40.104:${toString cfg.port}:${toString cfg.port}"
        ];
        environment = {
          PGADMIN_LISTEN_PORT = toString cfg.port;
          PGADMIN_DEFAULT_EMAIL = "admin@db.joshuabell.xyz";
          PGADMIN_DEFAULT_PASSWORD = "password";
        };
        volumes = [
          "${cfg.dataDir}:/var/lib/pgadmin"
        ];
        extraOptions = [
          "--network=host"
        ];
      };
    };
  };
}
