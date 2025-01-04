{
  config,
  pkgs,
  ...
}:
{

# NOTE some useful links
# nixos containers: https://blog.beardhatcode.be/2020/12/Declarative-Nixos-Containers.html
# https://nixos.wiki/wiki/NixOS_Containers
# 

  options.services.librechat =
    let
      lib = pkgs.lib;
    in
    {
      enable = lib.mkEnableOption "LibreChat service";
      port = lib.mkOption {
        type = lib.types.port;
        default = 3080;
        description = "Port number for the LibreChat API service";
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
    ## Give internet access
    # networking.nat.enable = true;
    # networking.nat.internalInterfaces = [ "ve-*" ];
    # networking.nat.externalInterface = "eth0";

    # Random test
    containers.wasabi = {
      ephemeral = true;
      autoStart = true;
      privateNetwork = true;
      hostAddress = "192.168.100.2";
      localAddress = "192.168.100.11";
      config =
        { config, pkgs, ... }:
        {
          system.stateVersion = "24.11";
          services.httpd.enable = true;
          services.httpd.adminAddr = "foo@example.org";
          networking.firewall = {
            enable = true;
            allowedTCPPorts = [ 80 ];
          };
        };
    };

    virtualisation.oci-containers = {
      backend = "docker"; # or "podman"
      containers = {
        # Example of defining a container from the compose file
        "test_nginx" = {
          # autoStart = true; this is default true
          image = "nginx:latest";
          ports = [
            "127.0.0.1:8085:80"
          ];
        };

        # librechat
        librechat = {
          image = "ghcr.io/danny-avila/librechat-dev:latest";
          ports = [
            "${toString config.services.librechat.port}:${toString config.services.librechat.port}"
          ];
          dependsOn = [
            "librechat_mongodb"
            "librechat_rag_api"
          ];
          environment = {
            HOST = "0.0.0.0";
            MONGO_URI = "mongodb://librechat_mongodb:27017/LibreChat";
            MEILI_HOST = "http://librechat_meilisearch:7700";
            RAG_PORT = toString config.services.librechat.ragPort;
            RAG_API_URL = "http://librechat_rag_api:${toString config.services.librechat.ragPort}";
          };
          environmentFiles = [ "${config.services.librechat.dataDir}/.env" ];
          volumes = [
            "${config.services.librechat.dataDir}/.env:/app/.env"
            "${config.services.librechat.dataDir}/librechat.yaml:/app/librechat.yaml"
            "${config.services.librechat.dataDir}/images:/app/client/public/images"
            "${config.services.librechat.dataDir}/logs:/app/api/logs"
          ];
          extraOptions = [ "--network=librechat-network" ];
        };

        librechat_mongodb = {
          image = "mongo";
          volumes = [
            "${config.services.librechat.dataDir}/data-node:/data/db"
          ];
          cmd = [
            "mongod"
            "--noauth"
          ];
          extraOptions = [ "--network=librechat-network" ];
        };

        librechat_meilisearch = {
          image = "getmeili/librechat_meilisearch:v1.7.3";
          environment = {
            MEILI_HOST = "http://librechat_meilisearch:7700";
            MEILI_NO_ANALYTICS = "true";
          };
          volumes = [
            "${config.services.librechat.dataDir}/meili_data_v1.7:/meili_data"
          ];
          extraOptions = [ "--network=librechat-network" ];
        };

        librechat_vectordb = {
          image = "ankane/pgvector:latest";
          environment = {
            POSTGRES_DB = "mydatabase";
            POSTGRES_USER = "myuser";
            POSTGRES_PASSWORD = "mypassword";
          };
          volumes = [
            "${config.services.librechat.dataDir}/pgdata2:/var/lib/postgresql/data"
          ];
          extraOptions = [ "--network=librechat-network" ];
        };

        librechat_rag_api = {
          image = "ghcr.io/danny-avila/librechat-rag-api-dev-lite:latest";
          environment = {
            DB_HOST = "librechat_vectordb";
            RAG_PORT = toString config.services.librechat.ragPort;
            OPENAI_API_KEY = "not_using_openai";
          };
          dependsOn = [ "librechat_vectordb" ];
          environmentFiles = [ "${config.services.librechat.dataDir}/.env" ];
          extraOptions = [ "--network=librechat-network" ];
        };

        # TODO revisit local whisper, for now I am using groq free for STT
        # librechat_whisper = {
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

    security.acme.acceptTerms = true;
    security.acme.email = "admin@joshuabell.xyz";
    services.nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts = {
        "local.belljm.com" = {
          # enableACME = true;
          # forceSSL = true;
          locations."/".proxyPass = "http://${config.containers.wasabi.localAddress}:80";
        };
        "127.0.0.1" = {
          locations."/wasabi/" = {
            extraConfig = ''
              rewrite ^/wasabi/(.*) /$1 break;
            '';
            proxyPass = "http://${config.containers.wasabi.localAddress}:80/";
          };
          locations."/" = {
            return = "404"; # or 444 for drop
          };
        };
        "_" = {
          default = true;
          locations."/" = {
            return = "404"; # or 444 for drop
          };
        };
      };
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
