{
  config,
  lib,
  inputs,
  ...
}:
let
  name = "immich";

  # Data stored on the wd10 drive
  hostDataDir = "/drives/wd10/immich";
  # Var lib for postgres and other state
  hostVarLibDir = "/var/lib/${name}";

  hostAddress = "10.0.0.1";
  containerAddress = "10.0.0.4";
  hostAddress6 = "fc00::1";
  containerAddress6 = "fc00::4";

  immichNixpkgs = inputs.immich-nixpkgs;

  # Secret file path (if using secrets)
  hasSecret =
    secret:
    let
      secrets = config.age.secrets or { };
    in
    secrets ? ${secret} && secrets.${secret} != null;

  binds = [
    # Postgres data, must use postgres user in container and host
    {
      host = "${hostVarLibDir}/postgres";
      # Adjust based on container postgres data dir
      container = "/var/lib/postgresql/16";
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
    # Immich media data on external drive
    {
      host = "${hostDataDir}/media";
      container = "/var/lib/immich";
      user = "immich";
      uid = 916;
      gid = 916;
    }
    # Immich machine learning cache
    {
      host = "${hostVarLibDir}/ml-cache";
      container = "/var/cache/immich";
      user = "immich";
      uid = 916;
      gid = 916;
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
    services.nginx.virtualHosts."photos.joshuabell.xyz" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
      locations = {
        "/" = {
          proxyWebsockets = true;
          recommendedProxySettings = true;
          proxyPass = "http://${containerAddress}:2283";
          extraConfig = ''
            proxy_set_header X-Forwarded-Proto https;
            client_max_body_size 50G;
          '';
        };
      };
    };

    # Ensure users exist on host machine
    inherit users;

    # Ensure directories exist on host machine
    system.activationScripts."createDirsFor${name}" = ''
      ${lib.concatStringsSep "\n" (
        lib.map (bind: ''
          mkdir -p ${bind.host}
          chown -R ${toString bind.uid}:${toString bind.gid} ${bind.host}
          chmod -R 750 ${bind.host}
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
      nixpkgs = immichNixpkgs;
      config =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        {
          config = lib.mkMerge [
            {
              system.stateVersion = "25.05";

              networking = {
                firewall = {
                  enable = true;
                  allowedTCPPorts = [
                    2283
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
                package = pkgs.postgresql_16.withPackages (ps: [ ps.pgvecto-rs ]);
                enableJIT = true;
                authentication = ''
                  local all all trust
                  host all all 127.0.0.1/8 trust
                  host all all ::1/128 trust
                  host all all fc00::1/128 trust
                '';
                ensureDatabases = [ "immich" ];
                ensureUsers = [
                  {
                    name = "immich";
                    ensureDBOwnership = true;
                    ensureClauses.login = true;
                  }
                ];
                settings = {
                  shared_preload_libraries = [ "vectors.so" ];
                };
              };

              # Backup database
              services.postgresqlBackup = {
                enable = true;
              };

              services.immich = {
                enable = true;
                host = "0.0.0.0";
                port = 2283;
                openFirewall = true;
                mediaLocation = "/var/lib/immich";
                database = {
                  enable = true;
                  createDB = false; # We create it manually above
                  name = "immich";
                  user = "immich";
                };
                redis.enable = true;
                machine-learning.enable = true;
                settings = {
                  server.externalDomain = "https://photos.joshuabell.xyz";
                  newVersionCheck.enabled = false;
                };
              };

              systemd.services.immich-server = {
                requires = [ "postgresql.service" ];
                after = [ "postgresql.service" ];
              };
            }
            {
              # Allow Immich user to access the media directory for hardware transcoding
              users.users.immich.extraGroups = [ "video" "render" ];
            }
          ];
        };
    };
  };
}
