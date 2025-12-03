{
  config,
  lib,
  inputs,
  ...
}:
let
  name = "forgejo";

  hostDataDir = "/var/lib/${name}";

  hostAddress = "10.0.0.1";
  containerAddress = "10.0.0.2";
  hostAddress6 = "fc00::1";
  containerAddress6 = "fc00::2";

  forgejoNixpkgs = inputs.forgejo-nixpkgs;

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
    # App data, uses custom user uid
    {
      host = "${hostDataDir}/data";
      container = "/var/lib/forgejo";
      user = "forgejo";
      uid = 115;
      gid = 115;
    }
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
  services.nginx = {
    virtualHosts = {
      # forgejo http traffic
      "git.joshuabell.xyz" = {
        addSSL = true;
        sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
        locations."/" = {
          proxyPass = "http://10.0.0.2:3000";
        };
      };
    };
    # STREAMS
    # Forgejo ssh
    streamConfig = ''
      server {
        listen 3032;
        proxy_pass 10.0.0.2:3032;
      }
    '';
  };

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
    hostAddress6 = hostAddress6;
    localAddress6 = containerAddress6;
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
    nixpkgs = forgejoNixpkgs;
    config =
      { config, pkgs, ... }:
      {
        system.stateVersion = "24.11";

        networking = {
          firewall = {
            enable = true;
            allowedTCPPorts = [
              3000
              3032
            ];
          };
          # Use systemd-resolved inside the container
          # Workaround for bug https://github.com/NixOS/nixpkgs/issues/162686
          useHostResolvConf = lib.mkForce false;
        };
        services.resolved.enable = true;

        # Ensure users exist on container
        inherit users;

        services.postgresql = {
          enable = true;
          package = pkgs.postgresql_17.withJIT;
          enableJIT = true;
          authentication = ''
            local all all trust
            host all all 127.0.0.1/8 trust
            host all all ::1/128 trust
            host all all fc00::1/128 trust
          '';
        };

        # Backup database
        services.postgresqlBackup = {
          enable = true;
        };

        services.forgejo = {
          enable = true;
          dump = {
            enable = false;
            type = "tar.gz";
          };
          database = {
            type = "postgres";
          };
          settings = {
            DEFAULT = {
              APP_NAME = "Josh's Git";
            };
            server = {
              PROTOCOL = "http";
              DOMAIN = "git.joshuabell.xyz";
              HTTP_ADDR = "0.0.0.0";
              HTTP_PORT = 3000;

              START_SSH_SERVER = true;
              SSH_DOMAIN = "git.joshuabell.xyz";
              SSH_LISTEN_HOST = "0.0.0.0";
              SSH_LISTEN_PORT = 3032; # actual listen port
              SSH_PORT = 3032; # used in UI
              BUILTIN_SSH_SERVER_USER = "git";

              LANDING_PAGE = "explore";
            };
            service = {
              DISABLE_REGISTRATION = true;
              ENABLE_BASIC_AUTHENTICATION = false;
              DISABLE_USERS_PAGE = true;
              DISABLE_ORGANIZATIONS_PAGE = true;
            };
            repository = {
              # ENABLE_PUSH_CREATE_USER = true;
              # ENABLE_PUSH_CREATE_ORG = true;
              DISABLE_STARS = true;
              DEFAULT_PRIVATE = "private";
            };
            admin = {
              DISABLE_REGULAR_ORG_CREATION = true;
              USER_DISABLED_FEATURES = "deletion";
            };
            other = {
              SHOW_FOOTER_POWERED_BY = false;
              SHOW_FOOTER_VERSION = false;
              SHOW_FOOTER_TEMPLATE_LOAD_TIME = false;
            };
            migrations = {
              ALLOWED_DOMAINS = "*.github.com,github.com,codeberg.org,*.codeberg.org";
              ALLOW_LOCALNETWORKS = true;
            };
          };
        };
      };
  };
}
