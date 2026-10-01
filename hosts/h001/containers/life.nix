# Life — personal life server, in a NixOS container.
#
# The application is not in nixpkgs: the life repo's flake exposes
# `nixosModules.default` (which also defaults `services.life.package` to its
# own build). This file supplies the container, the bind mounts, the secrets
# and the vhost; everything about the application comes from that module.
#
# Two services run inside:
#   life        the Rust server, which also serves the web client
#   postgresql  PostgreSQL 18 (created by the module), peer auth over the socket
# plus pgBackRest WAL archiving/base backups and the nightly logical + restic
# backup. Only the one HTTP port leaves the container.
{
  constants,
  config,
  lib,
  inputs,
  fleet,
  ...
}:
let
  name = "life";
  c = constants.services.life;
  net = constants.containerNetwork;

  # Hydrated by sec-agent (hosts/h001/sec-agent.nix) and bind-mounted
  # read-only. sec-agent's tmpfiles rules create an empty placeholder at each
  # path, so the container still starts before a value is set — but pgBackRest
  # then has no cipher pass (WAL archiving and base backups fail) and the
  # nightly backup has no restic repository (it fails). The server itself
  # needs neither.
  secrets = {
    pgbackrest = {
      host = "/var/lib/secrets_manager_hydrated/life_pgbackrest_2026-09-30";
      container = "/run/secrets/life-pgbackrest.conf";
    };
    backupEnv = {
      host = "/var/lib/secrets_manager_hydrated/life_backup_env_2026-09-30";
      container = "/run/secrets/life-backup.env";
    };
  };

  binds = [
    # Application state: blobs, published releases and the nightly logical
    # archives (/var/lib/life/{blobs,releases,backups}). The container is
    # ephemeral, so all of it must live on the host.
    #
    # Releases use the module default releaseDir, i.e. host path
    # ${c.dataDir}/state/releases. APKs are published by rsync as root to
    # root@h001:/var/lib/life/state/releases; the server only reads them.
    {
      host = "${c.dataDir}/state";
      container = "/var/lib/life";
      user = "life";
      uid = c.uid;
      gid = c.gid;
    }
    # PostgreSQL 18 cluster (services.postgresql.dataDir default).
    {
      host = "${c.dataDir}/postgres";
      container = "/var/lib/postgresql/18";
      user = "postgres";
      uid = config.ids.uids.postgres;
      gid = config.ids.gids.postgres;
    }
    # Local pgBackRest repository (repo1, encrypted with the cipher pass).
    {
      host = "${c.dataDir}/pgbackrest";
      container = "/var/lib/pgbackrest";
      user = "postgres";
      uid = config.ids.uids.postgres;
      gid = config.ids.gids.postgres;
    }
  ];

  uniqueUsers = lib.foldl' (
    acc: bind: if lib.lists.any (item: item.user == bind.user) acc then acc else acc ++ [ bind ]
  ) [ ] binds;

  # Same ids on the host and in the container, so bind-mount ownership matches.
  users = {
    users = lib.listToAttrs (
      lib.map (u: {
        name = u.user;
        value = {
          isSystemUser = true;
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
  services.nginx.virtualHosts."${c.domain}" = {
    addSSL = true;
    sslCertificate = "/var/lib/acme/${fleet.global.domain}/fullchain.pem";
    sslCertificateKey = "/var/lib/acme/${fleet.global.domain}/key.pem";

    # Client IP. Public traffic is client -> o002 nginx -> (tailnet) this
    # nginx -> container, and Life takes the LAST X-Forwarded-For entry as the
    # client (trustForwardedFor). o002 appends the client's address, so here
    # the last entry is the client; without realip this nginx would append
    # o002's overlay address after it. Trusting only o002, realip replaces
    # $remote_addr with that last entry, and the recommended
    # `X-Forwarded-For $proxy_add_x_forwarded_for` then ends with the client
    # again. Tailnet/LAN clients reaching this vhost directly are not trusted,
    # so their own address stays last whatever header they send.
    extraConfig = ''
      set_real_ip_from ${fleet.hosts.o002.overlayIp};
      real_ip_header X-Forwarded-For;
    '';

    locations."/" = {
      # No websocket endpoint yet; live sync for rich notes will need one.
      proxyWebsockets = true;
      recommendedProxySettings = true;
      proxyPass = "http://${c.containerIp}:${toString c.port}";
      extraConfig = ''
        proxy_set_header X-Forwarded-Proto https;

        # Blob uploads are up to 100 MiB (resumable); stream them to the
        # server instead of spooling the body to disk first.
        client_max_body_size 110m;
        proxy_request_buffering off;

        # Long uploads/downloads (Range, ~20 MB APKs) and future live sync.
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
      '';
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

    bindMounts =
      lib.listToAttrs (
        map (bind: {
          name = bind.container;
          value = {
            hostPath = bind.host;
            isReadOnly = false;
          };
        }) binds
      )
      // lib.mapAttrs' (_: s: {
        name = s.container;
        value = {
          hostPath = s.host;
          isReadOnly = true;
        };
      }) secrets;

    config =
      { lib, ... }:
      {
        imports = [ inputs.life.nixosModules.default ];
        system.stateVersion = "26.05";

        networking = {
          firewall = {
            enable = true;
            allowedTCPPorts = [ c.port ];
          };
          # Workaround for https://github.com/NixOS/nixpkgs/issues/162686
          useHostResolvConf = lib.mkForce false;
        };
        services.resolved.enable = true;

        inherit users;

        services.life = {
          enable = true;
          publicOrigin = "https://${c.domain}";
          listen = "0.0.0.0:${toString c.port}";
          # The host nginx in front sets X-Forwarded-For (see the vhost above).
          trustForwardedFor = true;

          # The IDs the life dev shell uses today. docs/cutover.md recommends a
          # dedicated Zitadel project for Life; whichever project is used, its
          # web app must list https://life.joshuabell.xyz/api/auth/callback
          # (post-logout https://life.joshuabell.xyz/) and its native app
          # xyz.joshuabell.life:/oauth2redirect as redirect URIs.
          zitadel = {
            issuer = "https://${constants.services.zitadel.domain}";
            projectId = "384694626893692931";
            webClientId = "393057818401374211";
            nativeClientId = "393057674100539395";
          };

          backup = {
            pgbackrest = {
              enable = true;
              secretsFile = secrets.pgbackrest.container;
            };
            # RESTIC_REPOSITORY / RESTIC_PASSWORD (+ offsite credentials) come
            # from the env file; given to the backup only, not to the server.
            nightly = {
              enable = true;
              restic.environmentFiles = [ secrets.backupEnv.container ];
            };
          };
        };
      };
  };
}
