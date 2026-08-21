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

  # The Zitadel *project* the application above belongs to. Roles are granted
  # per project, and Zitadel puts them in a claim named after the project id
  # ("urn:zitadel:iam:org:project:<id>:roles"), so the server needs the id to
  # know which claim carries the authorization decision. Reading the roles out
  # of the wrong claim, or guessing, fails closed: every request 403s.
  #
  # Public in the same way the client id is — it appears in issued tokens.
  oidcProjectId = "384694626893692931";

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
    # Published application artifacts — the signed Android APK the phone
    # updates itself from, served over the authenticated /api/releases route.
    #
    # Deliberately the only bind here with no `user`. The activation script
    # above chowns and `chmod 750`s every bind that names one, which is
    # correct for state the service writes and exactly wrong for this: it is
    # written from a laptop over `scp` as luser and only *read* by the
    # container. Adding a `user` here would take away the write access that
    # makes publishing a plain copy.
    #
    # `readOnly` for the same reason — the server has no business modifying a
    # build artifact, and a signed APK it could rewrite is a worse thing to
    # serve than one it cannot.
    #
    # The container path is under /var/lib rather than mirroring the host's
    # /home/luser, because pkm-server runs with `ProtectHome = true`: /home is
    # replaced by an empty tmpfs for that unit, so a release directory there
    # would silently appear empty. The pkm module asserts against it.
    {
      host = "/home/luser/pkm-releases";
      container = "/var/lib/pkm-releases";
      readOnly = true;
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
        #
        # This hangs off postgresql-setup, not postgresql, for two reasons.
        # postgresql-setup is what `ensureDatabases` runs in, so it is the
        # first point at which `powersync_storage` exists at all — the same
        # statement on postgresql.service would run before the database was
        # created and fail on a fresh volume. And a failing ExecStartPost on
        # postgresql.service takes the *server* down with it, turning a
        # one-line grant into a boot loop that also stops pkm-server and the
        # sync service, since both require postgresql.service.
        #
        # `psql` and not `$PSQL`: no such variable is exported into these
        # units. Referencing it produced `-tAc: command not found` (exit 127),
        # which is precisely the boot loop described above.
        systemd.services.postgresql-setup.postStart = lib.mkAfter ''
          psql -tAc 'GRANT ALL ON DATABASE "powersync_storage" TO "pkm";'
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
            projectId = oidcProjectId;
          };

          # What the *browser* is told to connect to, so it is the public URL
          # rather than the container-local port.
          syncEndpoint = "https://${c.domain}/powersync";

          # Signed builds, published by `scp`ing an APK to ~luser/pkm-releases
          # on the host. The bind mount above makes that directory visible
          # here read-only; the server parses the version out of each
          # filename, so publishing is a copy and nothing else.
          releaseDir = "/var/lib/pkm-releases";

          # Local speech-to-text for uploaded recordings.
          #
          # CPU inference, which is the only option here: this machine has no
          # discrete GPU, just the integrated one. It is better suited than
          # that sounds -- the i5-11500 has AVX-512 including VNNI, which is
          # exactly the instruction set whisper.cpp's CPU backend accelerates
          # with, and the quantised turbo model is small enough to stay
          # comfortably in RAM.
          #
          # Transcription is CPU-hungry while it runs, so it competes with the
          # server and Postgres in this container. Jobs are queued rather than
          # run on upload, which keeps that off the request path.
          whisper.enable = true;

          # The native apps — the Android APK and the desktop binary — serve
          # their bundle from a `tauri://` origin, so they reach this server
          # cross-origin even though it is their own backend. Without these
          # every request they make fails preflight, which presents as the
          # app being unable to load anything rather than as a CORS error.
          #
          # The browser is unaffected: it loads the frontend from this server
          # and stays same-origin, which is why this list names only the
          # webview origins.
          #
          # The two origins differ by platform, and not in the way the naming
          # suggests. Tauri's `tauri_protocol_url` (manager/mod.rs) returns
          # `{http,https}://tauri.localhost` only on Windows and Android — a
          # workaround for what those webviews accept as a custom protocol —
          # and plain `tauri://localhost` everywhere else, Linux included.
          #
          # So the desktop binary and the phone genuinely present different
          # Origin headers, and listing only one silently breaks the other.
          allowedOrigins = [
            # Android (the APK's webview).
            "http://tauri.localhost"
            "https://tauri.localhost"
            # Linux desktop (WebKitGTK).
            "tauri://localhost"
          ];

          powersync = {
            enable = true;
            port = c.syncPort;

            # TCP on loopback, not the unix socket pkm-server uses — and with
            # a password that is deliberately fake.
            #
            # Both details are forced by the sync service, and getting either
            # wrong stops it booting at all:
            #
            #   1. PowerSync has no unix-socket support. It parses the URI
            #      with urijs and reads only scheme/host/port/user/password/
            #      path; `?host=/run/postgresql` is simply ignored, leaving an
            #      empty hostname. The previous socket URI here therefore
            #      failed with PSYNC_S1108 ("password required") on every
            #      start, crash-looping ~128 times before this was found. The
            #      symptom is not a sync error: nothing ever listens on the
            #      sync port, so nginx returns 502 for /sync/stream and the
            #      app silently serves reads from an empty local database.
            #
            #   2. normalizeConnectionConfig rejects an empty password
            #      outright, before any connection is attempted. There is no
            #      "trust me" option.
            #
            # So a non-empty password must appear here even though nothing
            # verifies it: pg_hba above is `trust` for 127.0.0.1, and role
            # `pkm` has no password set at all. This string is a placeholder
            # to satisfy a client-side assertion, not a credential — which is
            # why it is safe in the world-readable Nix store, and why it must
            # stay meaningless. Should the pg_hba lines ever change to md5 or
            # scram, this stops working immediately and loudly, which is the
            # behaviour we want from a fake secret.
            replicationUri = "postgresql://pkm:unused@127.0.0.1:5432/pkm";
            storageUri = "postgresql://pkm:unused@127.0.0.1:5432/powersync_storage";
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
