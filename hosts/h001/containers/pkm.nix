# pkm — personal knowledge system, in a NixOS container.
#
# Unlike most containers here, the application is not packaged in nixpkgs: it
# lives in its own repo, which exposes a `nixosModules.pkm` and the matching
# packages. This file supplies the container, its Postgres, and the public
# vhost; everything about the application itself comes from that module.
#
# Three services run inside:
#   pkm-server     the Rust API, which also serves the built Svelte frontend
#                  (embedded in the binary, so the app is same-origin with its
#                  own API and no CORS configuration exists anywhere)
#   pkm-powersync  the sync service, replicating from the local Postgres
#   postgresql     the database, with PostGIS and logical replication
#
# The whole stack is inside one container deliberately: Postgres is reached
# over loopback, the sync service's deploy API is never exposed beyond it, and
# the only thing the host proxies is the one HTTP port.
{
  constants,
  config,
  lib,
  inputs,
  fleet,
  ...
}:
let
  name = "pkm";
  c = constants.services.pkm;
  net = constants.containerNetwork;

  hostDataDir = c.dataDir;

  hostAddress = net.hostAddress;
  containerAddress = c.containerIp;
  hostAddress6 = net.hostAddress6;
  containerAddress6 = c.containerIp6;

  # Zitadel is on this same host. The container reaches it over the public
  # name rather than the container IP, because the issuer in a token must
  # match what the client saw — a JWT issued for https://sso.joshuabell.xyz
  # does not validate against http://10.0.0.3:8080.
  oidcIssuer = "https://${constants.services.zitadel.domain}";

  # The Zitadel application ("pkm-web", type User Agent, PKCE, authorization
  # code only). A client id is public by design — it travels in every
  # authorization request — so it belongs in configuration rather than in
  # OpenBao.
  oidcClientId = "384694980708466691";

  binds = [
    # Application state: blob bytes and the sync signing key.
    #
    # The signing key is the reason this is a bind mount rather than container
    # state: the container is `ephemeral`, and regenerating that key on every
    # restart would invalidate every sync token already issued to a client.
    {
      host = "${hostDataDir}/state";
      container = "/var/lib/pkm";
      user = "pkm";
      uid = 981;
      gid = 981;
    }
    # Postgres data, owned by the same uid inside and outside.
    {
      host = "${hostDataDir}/postgres";
      container = "/var/lib/postgresql/17";
      user = "postgres";
      uid = config.ids.uids.postgres;
      gid = config.ids.gids.postgres;
    }
    {
      host = "${hostDataDir}/backups/postgres";
      container = "/var/backup/postgresql";
      user = "postgres";
      uid = config.ids.uids.postgres;
      gid = config.ids.gids.postgres;
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
  services.nginx = {
    virtualHosts = {
      "${c.domain}" = {
        addSSL = true;
        sslCertificate = "/var/lib/acme/${fleet.global.domain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${fleet.global.domain}/key.pem";

        locations = {
          "/" = {
            proxyWebsockets = true;
            recommendedProxySettings = true;
            proxyPass = "http://${containerAddress}:${toString c.port}";
            extraConfig = ''
              proxy_set_header X-Forwarded-Proto https;

              # Blob uploads are whole photos and audio recordings. nginx's
              # 1m default would reject them with a 413 that looks, from the
              # app, like the server rejecting the file itself.
              client_max_body_size 512m;
            '';
          };

          # The sync service, on the same origin under a path prefix.
          #
          # Same origin rather than a second subdomain so the browser treats
          # sync as first-party and no extra certificate is needed. The prefix
          # is stripped: the service has no notion of being mounted under one.
          #
          # proxyWebsockets is not optional — the sync protocol upgrades the
          # connection, and without it clients fall back to polling or fail
          # outright.
          "/powersync/" = {
            proxyWebsockets = true;
            recommendedProxySettings = true;
            proxyPass = "http://${containerAddress}:${toString c.syncPort}/";
            extraConfig = ''
              proxy_set_header X-Forwarded-Proto https;

              # A sync stream is a long-lived response that is deliberately
              # idle between changes. The 60s default would sever it roughly
              # once a minute, which shows up as sync that reconnects forever
              # and never settles.
              proxy_read_timeout 1h;
              proxy_send_timeout 1h;
              proxy_buffering off;
            '';
          };
        };
      };
    };
  };

  # Ensure users exist on the host with the same ids as in the container.
  inherit users;

  system.activationScripts."createDirsFor${name}" = ''
    ${lib.concatStringsSep "\n" (
      lib.map (bind: ''
        mkdir -p ${bind.host}
        chown ${toString bind.user}:${toString bind.gid} ${bind.host}
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

    config =
      {
        config,
        pkgs,
        lib,
        ...
      }:
      {
        imports = [ inputs.pkm.nixosModules.pkm ];

        system.stateVersion = "25.05";

        networking = {
          firewall = {
            enable = true;
            # Both ports are proxied by the host's nginx. The sync port is
            # open to the container network for that reason and no other; it
            # is not reachable from outside the host.
            allowedTCPPorts = [
              c.port
              c.syncPort
            ];
          };
          # Workaround for https://github.com/NixOS/nixpkgs/issues/162686
          useHostResolvConf = lib.mkForce false;
        };
        services.resolved.enable = true;

        inherit users;

        services.postgresql = {
          enable = true;
          package = pkgs.postgresql_17.withJIT;
          enableJIT = true;

          # PostGIS: the first migration does `create extension postgis`, so
          # the extension has to be available in the package or the server
          # fails its own migrations on first boot.
          extensions = ps: [ ps.postgis ];

          authentication = ''
            local all all trust
            host all all 127.0.0.1/8 trust
            host all all ::1/128 trust
            host all all fc00::1/128 trust
          '';

          settings = {
            # PowerSync replicates off the write-ahead log, which requires
            # logical decoding. Without this the sync service starts, finds it
            # cannot create a replication slot, and never syncs anything —
            # while both services report themselves healthy.
            wal_level = "logical";
            max_replication_slots = 10;
            max_wal_senders = 10;
          };

          ensureDatabases = [
            "pkm"
            # The sync service's bucket storage. A separate database, not just
            # a schema, so the service cannot reach application tables through
            # its storage connection.
            "powersync_storage"
          ];

          ensureUsers = [
            {
              name = "pkm";
              ensureDBOwnership = true;
              ensureClauses.login = true;
              # The server issues DDL of its own: adding a Postgres-backed
              # field creates or alters `core.data_<type>`. It also needs to
              # create the `powersync` publication, which requires ownership
              # of the database.
              ensureClauses.superuser = true;
            }
          ];
        };

        # The `powersync_storage` database needs an owner, and
        # `ensureDBOwnership` only applies to a database matching the user's
        # name. Granting it explicitly is the remaining piece.
        systemd.services.postgresql.postStart = lib.mkAfter ''
          $PSQL -tAc "GRANT ALL ON DATABASE powersync_storage TO pkm;"
        '';

        services.postgresqlBackup = {
          enable = true;
          databases = [ "pkm" ];
        };

        services.pkm = {
          enable = true;
          port = c.port;
          dataDir = "/var/lib/pkm";

          # Unix socket, not TCP: the database is in this container and a
          # socket needs no password and cannot be reached from the network.
          databaseUrl = "postgres:///pkm?host=/run/postgresql&user=pkm";

          oidc = {
            issuer = oidcIssuer;
            clientId = oidcClientId;
          };

          # What the *browser* is told to connect to, so it is the public URL
          # rather than the container-local port.
          syncEndpoint = "https://${c.domain}/powersync";

          powersync = {
            enable = true;
            port = c.syncPort;
            replicationUri = "postgresql://pkm@localhost/pkm?host=/run/postgresql";
            storageUri = "postgresql://pkm@localhost/powersync_storage?host=/run/postgresql";
            sslmode = "disable";
          };
        };

        systemd.services.pkm-server = {
          requires = [ "postgresql.service" ];
          after = [ "postgresql.service" ];
        };

        systemd.services.pkm-powersync = {
          requires = [ "postgresql.service" ];
          after = [ "postgresql.service" ];
        };
      };
  };
}
