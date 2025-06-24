{
  config,
  pkgs,
  ...
}:
let
  cfg = config.services.librechat;
in
{
  options.services.librechat =
    let
      lib = pkgs.lib;
    in
    {
      port = lib.mkOption {
        type = lib.types.port;
        default = 3080;
        description = "Port number for the LibreChat";
      };
      ragPort = lib.mkOption {
        type = lib.types.port;
        default = 8000;
        description = "Port number for the RAG API service";
      };
      dataDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/librechat";
        description = "Directory to store LibreChat data";
      };
    };

  config = {
    systemd.services.create-librechat-network = {
      description = "Create Docker network for LibreChat";
      serviceConfig.Type = "oneshot";
      wantedBy = [ "multi-user.target" ];
      script = ''
        if ! ${pkgs.docker}/bin/docker network inspect librechat-network >/dev/null 2>&1; then
          ${pkgs.docker}/bin/docker network create librechat-network
        fi
      '';
    };

    virtualisation.oci-containers.containers = {
      #############
      # librechat #
      #############
      # NOTE settings live in `/var/lib/librechat` manually right now
      librechat = {
        user = "root";
        image = "ghcr.io/danny-avila/librechat-dev:latest";
        ports = [
          "${toString cfg.port}:${toString cfg.port}"
        ];
        dependsOn = [
          "librechat_mongodb"
          "librechat_rag_api"
        ];
        environment = {
          HOST = "0.0.0.0";
          MONGO_URI = "mongodb://librechat_mongodb:27017/LibreChat";
          SEARCH = "true";
          MEILI_HOST = "http://librechat_meilisearch:7700";
          MEILI_NO_ANALYTICS = "true";
          MEILI_MASTER_KEY = "ringofstormsLibreChat";
          RAG_PORT = toString cfg.ragPort;
          RAG_API_URL = "http://librechat_rag_api:${toString cfg.ragPort}";
          # DEBUG_CONSOLE = "true";
          # DEBUG_LOGGING = "true";
        };
        environmentFiles = [ "${cfg.dataDir}/.env" ];
        volumes = [
          "${cfg.dataDir}/.env:/app/.env"
          "${cfg.dataDir}/librechat.yaml:/app/librechat.yaml"
          "${cfg.dataDir}/images:/app/client/public/images"
          "${cfg.dataDir}/logs:/app/api/logs"
        ];
        extraOptions = [
          "--network=librechat-network"
          "--add-host=azureproxy:100.64.0.8"
          "--add-host=ollamaproxy:100.64.0.6"
        ];
      };

      librechat_mongodb = {
        user = "root";
        image = "mongo";
        volumes = [
          "${cfg.dataDir}/data-node:/data/db"
        ];
        cmd = [
          "mongod"
          "--noauth"
        ];
        extraOptions = [ "--network=librechat-network" ];
      };

      librechat_meilisearch = {
        user = "root";
        image = "getmeili/meilisearch:v1.12.3";
        environment = {
          MEILI_HOST = "http://librechat_meilisearch:7700";
          MEILI_NO_ANALYTICS = "true";
          MEILI_MASTER_KEY = "ringofstormsLibreChat";
        };
        volumes = [
          "${cfg.dataDir}/meili_data_v1.12:/meili_data"
        ];
        extraOptions = [ "--network=librechat-network" ];
      };

      librechat_vectordb = {
        user = "root";
        image = "ankane/pgvector:latest";
        environment = {
          POSTGRES_DB = "mydatabase";
          POSTGRES_USER = "myuser";
          POSTGRES_PASSWORD = "mypassword";
        };
        volumes = [
          "${cfg.dataDir}/pgdata2:/var/lib/postgresql/data"
        ];
        extraOptions = [ "--network=librechat-network" ];
      };

      librechat_rag_api = {
        user = "root";
        image = "ghcr.io/danny-avila/librechat-rag-api-dev-lite:latest";
        environment = {
          DB_HOST = "librechat_vectordb";
          RAG_PORT = toString cfg.ragPort;
          OPENAI_API_KEY = "not_using_openai";
        };
        dependsOn = [ "librechat_vectordb" ];
        environmentFiles = [ "${cfg.dataDir}/.env" ];
        extraOptions = [ "--network=librechat-network" ];
      };

      # TODO revisit local whisper, for now I am using groq free for STT
      # librechat_whisper = {
      # user = "root";
      #   image = "onerahmet/openai-whisper-asr-webservice:latest";
      #   # ports = [ "8080:8080" ];
      #   environment = {
      #     ASR_MODEL = "base"; # You can change to small, medium, large, etc.
      #     ASR_ENGINE = "openai_whisper";
      #   };
      #   extraOptions = [ "--network=librechat-network" ];
      # };
    };
  };
}
