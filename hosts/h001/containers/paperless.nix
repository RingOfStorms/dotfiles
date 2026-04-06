{
  constants,
  config,
  lib,
  inputs,
  fleet,
  ...
}:
let
  name = "paperless";
  c = constants.services.paperless;
  net = constants.containerNetwork;
  postgresVersion = "16";

  # Document data stored on the wd10 drive
  hostDataDir = c.dataDir;
  # Var lib for postgres and other state
  hostVarLibDir = c.varLibDir;

  hostAddress = net.hostAddress;
  containerAddress = c.containerIp;
  hostAddress6 = net.hostAddress6;
  containerAddress6 = c.containerIp6;

  paperlessNixpkgs = inputs.paperless-nixpkgs;

  binds = [
    # Postgres data
    {
      host = "${hostVarLibDir}/postgres";
      container = "/var/lib/postgresql/${postgresVersion}";
      user = "postgres";
      uid = config.ids.uids.postgres;
      gid = config.ids.gids.postgres;
    }
    # Postgres backups
    {
      host = "${hostVarLibDir}/backups/postgres";
      container = "/var/backup/postgresql";
      user = "postgres";
      uid = config.ids.uids.postgres;
      gid = config.ids.gids.postgres;
    }
    # Paperless data directory (DB state, index, etc.)
    {
      host = "${hostVarLibDir}/data";
      container = "/var/lib/paperless";
      user = "paperless";
      uid = c.uid;
      gid = c.gid;
    }
    # Paperless media (actual document files) on external drive
    {
      host = "${hostDataDir}/media";
      container = "/var/lib/paperless/media";
      user = "paperless";
      uid = c.uid;
      gid = c.gid;
    }
    # Paperless consumption directory on external drive
    {
      host = "${hostDataDir}/consume";
      container = "/var/lib/paperless/consume";
      user = "paperless";
      uid = c.uid;
      gid = c.gid;
    }
  ];

  bindsWithUsers = lib.filter (b: b ? user) binds;
  uniqueUsers = lib.foldl' (
    acc: bind: if lib.lists.any (item: item.user == bind.user) acc then acc else acc ++ [ bind ]
  ) [ ] bindsWithUsers;
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
  options = { };
  config = {
    services.nginx.virtualHosts."${c.domain}" = {
      listen = [
        { addr = constants.host.overlayIp; port = 443; ssl = true; }
      ];
      sslCertificate = "/var/lib/acme/${fleet.global.domain}/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/${fleet.global.domain}/key.pem";
      extraConfig = ''
        client_max_body_size 100M;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        send_timeout 600s;
      '';
      locations."/" = {
        proxyWebsockets = true;
        proxyPass = "http://${containerAddress}:${toString c.port}";
      };
    };

    # Ensure users exist on host machine
    inherit users;

    # Ensure directories exist on host machine
    system.activationScripts."createDirsFor${name}" = ''
      ${lib.concatStringsSep "\n" (
        lib.map (bind: ''
          mkdir -p ${bind.host}
          chown ${toString bind.uid}:${toString bind.gid} ${bind.host}
          chmod 750 ${bind.host}
        '') bindsWithUsers
      )}
    '';

    containers.${name} = {
      ephemeral = true;
      autoStart = true;
      privateNetwork = true;
      hostAddress = hostAddress;
      localAddress = containerAddress;
      hostAddress6 = hostAddress6;
      localAddress6 = containerAddress6;
      bindMounts = lib.foldl (
        acc: bind:
        {
          "${bind.container}" = {
            hostPath = bind.host;
            isReadOnly = bind.readOnly or false;
          };
        }
        // acc
      ) { } binds;
      nixpkgs = paperlessNixpkgs;
      config =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        {
          config = {
            system.stateVersion = "25.05";

            networking = {
              firewall = {
                enable = true;
                allowedTCPPorts = [
                  c.port
                ];
              };
              # Use systemd-resolved inside the container
              # Workaround for bug https://github.com/NixOS/nixpkgs/issues/162686
              useHostResolvConf = lib.mkForce false;
            };
            services.resolved.enable = true;

            # Override paperless user UID/GID to match host bind mount ownership
            # (the paperless module creates this user automatically with config.ids.uids.paperless)
            users.users.paperless.uid = lib.mkForce c.uid;
            users.groups.paperless.gid = lib.mkForce c.gid;

            services.postgresql = {
              enable = true;
              package = pkgs.${"postgresql_${postgresVersion}"};
              enableJIT = true;
              authentication = ''
                local all all trust
                host all all 127.0.0.1/8 trust
                host all all ::1/128 trust
                host all all fc00::1/128 trust
              '';
              ensureDatabases = [ "paperless" ];
              ensureUsers = [
                {
                  name = "paperless";
                  ensureDBOwnership = true;
                  ensureClauses.login = true;
                }
              ];
            };

            # Backup database
            services.postgresqlBackup = {
              enable = true;
            };

            services.paperless = {
              enable = true;
              address = "0.0.0.0";
              port = c.port;
              dataDir = "/var/lib/paperless";
              mediaDir = "/var/lib/paperless/media";
              consumptionDir = "/var/lib/paperless/consume";
              database.createLocally = false; # We create it manually above
              configureTika = true;
              settings = {
                PAPERLESS_URL = "https://${c.domain}";
                PAPERLESS_DBENGINE = "postgresql";
                PAPERLESS_DBHOST = "/run/postgresql";
                PAPERLESS_DBNAME = "paperless";
                PAPERLESS_DBUSER = "paperless";
                PAPERLESS_OCR_LANGUAGE = "eng";
                PAPERLESS_CONSUMER_RECURSIVE = true;
                PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS = true;
              };
            };

            systemd.services.paperless-scheduler = {
              requires = [ "postgresql.service" ];
              after = [ "postgresql.service" ];
            };
          };
        };
    };
  };
}
