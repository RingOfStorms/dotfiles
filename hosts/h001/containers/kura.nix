# Kura production stack, independent of the legacy PKM deployment.
{
  constants,
  config,
  lib,
  inputs,
  fleet,
  ...
}:
let
  name = "kura";
  c = constants.services.kura;
  net = constants.containerNetwork;
  secretHostPath = "/var/lib/secrets_manager_hydrated/kura_env_2026-09-05";
  secretContainerPath = "/run/secrets/kura.env";

  binds = [
    {
      host = "${c.dataDir}/state";
      container = "/var/lib/kura";
      user = "kura";
      uid = 980;
      gid = 980;
    }
    {
      host = "${c.dataDir}/postgres";
      container = "/var/lib/postgresql/17";
      user = "postgres";
      uid = config.ids.uids.postgres;
      gid = config.ids.gids.postgres;
    }
    {
      host = "${c.dataDir}/backups/postgres";
      container = "/var/backup/postgresql";
      user = "postgres";
      uid = config.ids.uids.postgres;
      gid = config.ids.gids.postgres;
    }
    {
      host = "${c.dataDir}/ocr";
      container = "/var/lib/kura-ocr";
      user = "root";
      uid = 0;
      gid = 0;
    }
    {
      host = "${c.dataDir}/podman";
      container = "/var/lib/containers";
      user = "root";
      uid = 0;
      gid = 0;
    }
  ];

  users = {
    users = {
      kura = {
        isSystemUser = true;
        uid = 980;
        group = "kura";
      };
      postgres = {
        isSystemUser = true;
        uid = config.ids.uids.postgres;
        group = "postgres";
      };
    };
    groups = {
      kura.gid = 980;
      postgres.gid = config.ids.gids.postgres;
    };
  };
in
{
  services.nginx.virtualHosts."${c.domain}" = {
    addSSL = true;
    sslCertificate = "/var/lib/acme/${fleet.global.domain}/fullchain.pem";
    sslCertificateKey = "/var/lib/acme/${fleet.global.domain}/key.pem";

    locations = {
      "/" = {
        proxyWebsockets = true;
        recommendedProxySettings = true;
        proxyPass = "http://${c.containerIp}:${toString c.port}";
        extraConfig = ''
          proxy_set_header X-Forwarded-Proto https;
          client_max_body_size 10m;
        '';
      };

      "/powersync/" = {
        proxyWebsockets = true;
        recommendedProxySettings = true;
        proxyPass = "http://${c.containerIp}:${toString c.syncPort}/";
        extraConfig = ''
          proxy_set_header X-Forwarded-Proto https;
          proxy_read_timeout 1h;
          proxy_send_timeout 1h;
          proxy_buffering off;
        '';
      };
    };
  };

  inherit users;

  system.activationScripts."createDirsFor${name}" = ''
    ${lib.concatMapStringsSep "\n" (bind: ''
      mkdir -p ${bind.host}
      chown ${toString bind.uid}:${toString bind.gid} ${bind.host}
      chmod 750 ${bind.host}
    '') binds}
  '';

  containers.${name} = {
    ephemeral = true;
    autoStart = true;
    privateNetwork = true;
    hostAddress = net.hostAddress;
    localAddress = c.containerIp;
    hostAddress6 = net.hostAddress6;
    localAddress6 = c.containerIp6;

    bindMounts = (lib.listToAttrs (map (bind: {
      name = bind.container;
      value = {
        hostPath = bind.host;
        isReadOnly = false;
      };
    }) binds)) // {
      "${secretContainerPath}" = {
        hostPath = secretHostPath;
        isReadOnly = true;
      };
    };

    config =
      { pkgs, lib, ... }:
      let
        ocrPodman = pkgs.writeShellScriptBin "kura-ocr-podman" ''
          set -eu
          case "''${1:-}" in
            build)
              shift
              exec ${lib.getExe pkgs.podman} --cgroup-manager=cgroupfs --runtime-flag=cgroup-manager=disabled build "$@"
              ;;
            run)
              shift
              exec ${lib.getExe pkgs.podman} --cgroup-manager=cgroupfs --runtime-flag=cgroup-manager=disabled run --cgroups=disabled "$@"
              ;;
            *) exec ${lib.getExe pkgs.podman} "$@" ;;
          esac
        '';
      in
      {
        imports = [ inputs.kura.nixosModules.kura ];
        system.stateVersion = "26.05";

        virtualisation.podman.enable = true;
        networking = {
          firewall = {
            enable = true;
            allowedTCPPorts = [ c.port c.syncPort ];
          };
          useHostResolvConf = lib.mkForce false;
        };
        services.resolved.enable = true;
        inherit users;

        services.postgresql = {
          enable = true;
          package = pkgs.postgresql_17.withJIT;
          enableJIT = true;
          authentication = ''
            local all all trust
            host all all 127.0.0.1/8 trust
            host all all ::1/128 trust
          '';
          settings = {
            wal_level = "logical";
            max_replication_slots = 10;
            max_wal_senders = 10;
          };
          ensureDatabases = [ "kura" "powersync_storage_kura" ];
          ensureUsers = [ {
            name = "kura";
            ensureDBOwnership = true;
            ensureClauses = {
              login = true;
              superuser = true;
            };
          } ];
        };

        systemd.services.postgresql-setup.postStart = lib.mkAfter ''
          psql -tAc 'GRANT ALL ON DATABASE "powersync_storage_kura" TO "kura";'
        '';

        services.kura = {
          enable = true;
          package = inputs.kura.packages.${pkgs.system}.kura-server;
          address = "0.0.0.0";
          port = c.port;
          serverPort = c.port + 1;
          dataDir = "/var/lib/kura";
          databaseUrl = "postgresql:///kura?host=/run/postgresql&user=kura";
          environmentFiles = [ secretContainerPath ];
          extraEnvironment.OCR_SERVICE_URL = "http://127.0.0.1:${toString c.ocrPort}";

          zitadel = {
            issuer = "https://${constants.services.zitadel.domain}";
            clientId = "389383293021257731";
            projectId = "384694626893692931";
            redirectUri = "https://${c.domain}/auth/callback";
            postLogoutRedirectUri = "https://${c.domain}/";
          };

          backup = {
            enable = true;
            location = "/var/backup/postgresql";
          };

          powersync = {
            enable = true;
            package = inputs.kura.packages.${pkgs.system}.powersync-service;
            publicUrl = "https://${c.domain}/powersync";
            port = c.syncPort;
            databaseUrl = "postgresql://kura:unused@127.0.0.1:5432/kura";
            storageDatabaseUrl = "postgresql://kura:unused@127.0.0.1:5432/powersync_storage_kura";
            environmentFiles = [ secretContainerPath ];
            allowedAddresses = [ "localhost" net.hostAddress ];
          };

          ocr = {
            enable = true;
            image = "localhost/kura-paddleocr-vl:1";
            dataDir = "/var/lib/kura-ocr";
            port = c.ocrPort;
            podmanPackage = ocrPodman;
          };
        };

        systemd.services = {
          kura-server = {
            requires = [ "postgresql.service" ];
            after = [ "postgresql.service" ];
          };
          kura-powersync = {
            requires = [ "postgresql.service" ];
            after = [ "postgresql.service" ];
          };
        };
      };
  };
}
