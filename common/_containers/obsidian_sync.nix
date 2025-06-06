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
    };

  config = {
    virtualisation.oci-containers.containers = {
      #############
      # obsidian_sync #
      #############
      obsidian_sync = {
        user = "root";
        image = "ghcr.io/danny-avila/obsidian_sync-dev:latest";
        ports = [
          "${toString cfg.port}:${toString cfg.port}"
        ];
        environment = {
          SERVER_URL = cfg.serverUrl;
          COUCHDB_USER = "adminu";
          COUCHDB_PASSWORD = "Password123"; # TODO move to a secret and link to it via envFiles
          COUCHDB_DATABASE = "obsidian_sync";
        };
        # environmentFiles = [ "${cfg.dataDir}/.env" ]; $ TODO see above todo
        volumes = [
          "${cfg.dataDir}/data:/opt/couchdb/data"
        ];
      };
    };
  };
}
