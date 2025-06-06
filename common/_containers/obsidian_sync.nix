{
  config,
  pkgs,
  ...
}:
let
  cfg = config.services.obsidian_sync;
in
{
  options.services.obsidian_sync =
    let
      lib = pkgs.lib;
    in
    {
      port = lib.mkOption {
        type = lib.types.port;
        default = 5984;
        description = "Port number for Obsidian Sync CouchDB server";
      };
      dataDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/obsidian_sync";
        description = "Directory to store Obsidian Sync data";
      };
      serverUrl = lib.mkOption {
        type = lib.types.str;
        description = "URL of the Obsidian Sync server";
      };
      dockerEnvFiles = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = "List of environment files to be used by the Obsidian Sync container";
      };
    };

  config = {
    virtualisation.oci-containers.containers = {
      #############
      # obsidian_sync #
      #############
      obsidian_sync = {
        user = "root";
        image = "docker.io/oleduc/docker-obsidian-livesync-couchdb:master";
        ports = [
          "${toString cfg.port}:${toString cfg.port}"
        ];
        environment = {
          SERVER_URL = cfg.serverUrl;
          COUCHDB_DATABASE = "obsidian_sync";
          COUCHDB_USER = "adminu";
          COUCHDB_PASSWORD = "Password123"; # TODO move to a secret and link to it via envFiles
        };
        environmentFiles = cfg.dockerEnvFiles;
        volumes = [
          "${cfg.dataDir}/data:/opt/couchdb/data"
        ];
      };
    };
  };
}
