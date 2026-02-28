# SETUP
# 1. Rebuild and wait for container to start:
#      sudo nixos-rebuild switch
#
# 2. Create accounts:
#      sudo nixos-container run matrix -- matrix-synapse-register_new_matrix_user \
#        -c /var/lib/matrix-synapse/secrets.yaml -u admin -a
#      sudo nixos-container run matrix -- matrix-synapse-register_new_matrix_user \
#        -c /var/lib/matrix-synapse/secrets.yaml -u josh --no-admin
#
# 3. Login at https://element.joshuabell.xyz
#
# 4. Pair bridges — DM each bot and follow its login flow:
#
#    Google Messages (@gmessagesbot):
#      - Send "login qr", scan QR with Google Messages on your phone
#      - Wait for conversations to sync (initial_chat_sync_count = 99999)
#
#    Signal (@signalbot):
#      - Send "login", bot shows QR code
#      - Phone: Signal → Settings → Linked Devices → Link New Device → scan QR
#      - Accept message history transfer for backfill
#
#    WhatsApp (@whatsappbot):
#      - Send "login", bot shows QR code
#      - Phone: WhatsApp → Settings → Linked Devices → Link a Device → scan QR
#      - Phone must stay online; linked device disconnects after ~2 weeks offline
#
#    Instagram (@instagrambot):
#      - Send "login-cookie"
#      - In a browser, log into instagram.com, open DevTools (F12) → Network tab
#      - Make any request, right-click → Copy as cURL
#      - Paste the full cURL command to the bot
#      - Meta may flag suspicious activity — use 2FA to reduce risk
#
#    Facebook Messenger (@facebookbot):
#      - Send "login-cookie"
#      - In a browser, log into messenger.com, open DevTools (F12) → Network tab
#      - Make any request, right-click → Copy as cURL
#      - Paste the full cURL command to the bot
#      - Same cookie-based auth as Instagram; sessions can expire
#
#    Discord (@discordbot):
#      - Send "login-qr", scan QR with Discord mobile app
#      - OR send "login-token", then paste your Discord auth token
#        (DevTools → Network → any request → Authorization header)
#      - Note: user account bridging technically violates Discord ToS
#      - For guild/server bridging: send "guilds" after login to list servers,
#        then "guilds bridge <id>" to bridge specific servers
#
#    Telegram (@telegrambot):
#      - Send "login"
#      - Bot asks for your phone number (international format, e.g. +1234567890)
#      - Enter the verification code Telegram sends you
#      - Enter 2FA password if enabled
#      - Note: Telegram API keys are configured in the bridge config, not at
#        login time. Default keys from mautrix-telegram are used.
#
# 5. Login as admin and josh via API (use external URL to avoid container rate limits):
#      ADMIN_TOKEN=$(jq -n --arg pass '<ADMIN_PASS>' \
#        '{type:"m.login.password",user:"admin",password:$pass}' | \
#        curl -s -X POST 'https://matrix.joshuabell.xyz/_matrix/client/v3/login' \
#        -H 'Content-Type: application/json' -d @- | jq -r '.access_token')
#
#      JOSH_TOKEN=$(jq -n --arg pass '<JOSH_PASS>' \
#        '{type:"m.login.password",user:"josh",password:$pass}' | \
#        curl -s -X POST 'https://matrix.joshuabell.xyz/_matrix/client/v3/login' \
#        -H 'Content-Type: application/json' -d @- | jq -r '.access_token')
#
# 6. Disable rate limiting for josh (as admin):
#      curl -s -X POST 'https://matrix.joshuabell.xyz/_synapse/admin/v1/users/@josh:matrix.joshuabell.xyz/override_ratelimit' \
#        -H "Authorization: Bearer $ADMIN_TOKEN" \
#        -H 'Content-Type: application/json' \
#        -d '{"messages_per_second": 0, "burst_count": 0}'
#
# 7. Join all pending bridge room invites:
#      Run scripts/matrix-join-all.sh (prompts for credentials, joins all invited rooms)
#
# 8. SMS/MMS Backfill (optional — injects historical messages from Android SMS export):
#    a. Export SMS from Android using "SMS Backup & Restore" app, copy XML to h001:
#         scp sms-export.xml h001:/tmp/sms-export.xml
#
#    b. Get the appservice token:
#         sudo nixos-container run matrix -- cat /var/lib/mautrix_gmessages/registration.yaml | grep as_token
#
#    c. Generate room map (maps phone numbers to bridge portal rooms):
#         Build: nix-shell -p go --run 'cd scripts/sms-backfill && go build -o /tmp/generate-room-map-bin ./cmd/generate-room-map'
#         Run:   /tmp/generate-room-map-bin --admin-token $ADMIN_TOKEN --homeserver https://matrix.joshuabell.xyz > /tmp/room-map.json
#
#    d. Stop the bridge before backfilling:
#         sudo nixos-container run matrix -- systemctl stop mautrix-gmessages
#
#    e. Dry run (verify matches, no API calls):
#         Build: nix-shell -p go --run 'cd scripts/sms-backfill && go build -o /tmp/sms-backfill-bin ./cmd/backfill'
#         Run:   /tmp/sms-backfill-bin \
#                  --file /tmp/sms-export.xml \
#                  --room-map /tmp/room-map.json \
#                  --homeserver https://matrix.joshuabell.xyz \
#                  --josh-phone +17202362288 \
#                  --dry-run
#
#    f. Run the actual backfill:
#         /tmp/sms-backfill-bin \
#           --file /tmp/sms-export.xml \
#           --room-map /tmp/room-map.json \
#           --homeserver https://matrix.joshuabell.xyz \
#           --josh-phone +17202362288 \
#           --as-token <AS_TOKEN>
#       Outgoing messages are sent as the bridge bot (@gmessagesbot) to avoid
#       the bridge relaying them as real SMS texts.
#       Groups are matched by sorted comma-separated phone numbers (with Josh's
#       own number stripped). Conversations without a bridge portal are skipped.
#
#    g. Restart the bridge:
#         sudo nixos-container run matrix -- systemctl start mautrix-gmessages
#
# NUCLEAR RESET (wipe everything and start over):
#   sudo nixos-container stop matrix
#   sudo rm -rf /var/lib/matrix/*
#   sudo nixos-rebuild switch
#   Then redo from step 2.
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  name = "matrix";
  hostDataDir = "/var/lib/${name}";
  hostAddress = "10.0.0.1";
  containerAddress = "10.0.0.6";

  # Use unstable nixpkgs for the container (mautrix-gmessages not in stable)
  matrixNixpkgs = inputs.matrix-nixpkgs;

  # Matrix server configuration
  serverName = "matrix.joshuabell.xyz";
  elementDomain = "element.joshuabell.xyz";

  # Bridge toggles — enable/disable individual bridges
  enableGmessages = true;
  enableSignal = true;
  enableInstagram = false;
  enableFacebook = false;
  enableWhatsapp = false;
  enableDiscord = false;
  enableTelegram = true;

  # Bind mount definitions following forgejo.nix pattern
  binds = [
    {
      host = "${hostDataDir}/postgres";
      container = "/var/lib/postgresql/17";
      user = "postgres";
      group = "postgres";
      uid = 71;
      gid = 71;
    }
    {
      host = "${hostDataDir}/backups";
      container = "/var/backup/postgresql";
      user = "postgres";
      group = "postgres";
      uid = 71;
      gid = 71;
    }
    {
      host = "${hostDataDir}/synapse";
      container = "/var/lib/matrix-synapse";
      user = "matrix-synapse";
      group = "matrix-synapse";
      uid = 198;
      gid = 198;
    }
  ]
  ++ lib.optionals enableGmessages [
    {
      host = "${hostDataDir}/gmessages";
      container = "/var/lib/mautrix_gmessages";
      user = "mautrix_gmessages";
      group = "mautrix_gmessages";
      uid = 992;
      gid = 992;
    }
  ]
  ++ lib.optionals enableSignal [
    {
      host = "${hostDataDir}/signal";
      container = "/var/lib/mautrix-signal";
      user = "mautrix-signal";
      group = "mautrix-signal";
      uid = 991;
      gid = 991;
    }
  ]
  ++ lib.optionals enableInstagram [
    {
      host = "${hostDataDir}/meta-instagram";
      container = "/var/lib/mautrix-meta-instagram";
      user = "mautrix-meta-instagram";
      group = "mautrix-meta";
      uid = 990;
      gid = 985;
    }
  ]
  ++ lib.optionals enableFacebook [
    {
      host = "${hostDataDir}/meta-facebook";
      container = "/var/lib/mautrix-meta-facebook";
      user = "mautrix-meta-facebook";
      group = "mautrix-meta";
      uid = 989;
      gid = 985;
    }
  ]
  ++ lib.optionals enableWhatsapp [
    {
      host = "${hostDataDir}/whatsapp";
      container = "/var/lib/mautrix-whatsapp";
      user = "mautrix-whatsapp";
      group = "mautrix-whatsapp";
      uid = 988;
      gid = 988;
    }
  ]
  ++ lib.optionals enableDiscord [
    {
      host = "${hostDataDir}/discord";
      container = "/var/lib/mautrix-discord";
      user = "mautrix-discord";
      group = "mautrix-discord";
      uid = 987;
      gid = 987;
    }
  ]
  ++ lib.optionals enableTelegram [
    {
      host = "${hostDataDir}/telegram";
      container = "/var/lib/mautrix-telegram";
      user = "mautrix-telegram";
      group = "mautrix-telegram";
      uid = 986;
      gid = 986;
    }
  ];

  uniqueUsers = lib.unique (map (b: { inherit (b) user uid group gid; }) binds);
  uniqueGroups = lib.unique (map (b: { inherit (b) group gid; }) binds);

  # Element Web configuration - points to our server, registration disabled
  elementConfig = {
    default_server_config = {
      "m.homeserver" = {
        base_url = "https://${serverName}";
        server_name = serverName;
      };
    };
    disable_guests = true;
    disable_login_language_selector = false;
    disable_3pid_login = true;
    brand = "Element";
    integrations_ui_url = "";
    integrations_rest_url = "";
    integrations_widgets_urls = [ ];
    show_labs_settings = false;
    room_directory = {
      servers = [ serverName ];
    };
    # Security: disable features that could leak data
    enable_presence_by_hs_url = { };
    permalink_prefix = "https://${elementDomain}";
  };

  elementConfigFile = pkgs.writeText "element-config.json" (builtins.toJSON elementConfig);

  # Custom Element Web with our config
  elementWebCustom = pkgs.runCommand "element-web-custom" { } ''
    cp -r ${pkgs.element-web} $out
    chmod -R u+w $out
    rm $out/config.json
    cp ${elementConfigFile} $out/config.json
  '';

in
{
  # Create host directories and users
  system.activationScripts."${name}-dirs" = lib.stringAfter [ "users" "groups" ] ''
    ${lib.concatMapStringsSep "\n" (b: ''
      mkdir -p ${b.host}
      chown ${toString b.uid}:${toString b.gid} ${b.host}
    '') binds}
  '';

  # Create users/groups on host for bind mount permissions
  users.users = lib.listToAttrs (
    map (u: {
      name = u.user;
      value = {
        isSystemUser = true;
        uid = u.uid;
        group = u.group;
      };
    }) (lib.filter (u: u.user != "postgres") uniqueUsers)
  );

  users.groups = lib.listToAttrs (
    map (g: {
      name = g.group;
      value = {
        gid = g.gid;
      };
    }) (lib.filter (g: g.group != "postgres") uniqueGroups)
  );

  # nginx reverse proxy on host
  services.nginx.virtualHosts = {
    # Matrix server - handles client API
    "${serverName}" = {
      forceSSL = true;
      useACMEHost = "joshuabell.xyz";

      # .well-known for Matrix client discovery
      locations."= /.well-known/matrix/server" = {
        return = ''200 '{"m.server": "${serverName}:443"}' '';
        extraConfig = ''
          default_type application/json;
          add_header Access-Control-Allow-Origin *;
        '';
      };

      locations."= /.well-known/matrix/client" = {
        return = ''200 '{"m.homeserver": {"base_url": "https://${serverName}"}}' '';
        extraConfig = ''
          default_type application/json;
          add_header Access-Control-Allow-Origin *;
        '';
      };

      # Matrix client API
      locations."/_matrix" = {
        proxyPass = "http://${containerAddress}:8008";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_read_timeout 600s;
          client_max_body_size 50M;
        '';
      };

      # Synapse admin API
      locations."/_synapse" = {
        proxyPass = "http://${containerAddress}:8008";
        proxyWebsockets = true;
      };

      # Default location - redirect to Element
      locations."/" = {
        return = "301 https://${elementDomain}";
      };
    };

    # Element Web client
    "${elementDomain}" = {
      forceSSL = true;
      useACMEHost = "joshuabell.xyz";

      locations."/" = {
        proxyPass = "http://${containerAddress}:80";
        proxyWebsockets = true;
      };
    };
  };

  # The container
  containers.${name} = {
    ephemeral = true;
    autoStart = true;
    privateNetwork = true;
    hostAddress = hostAddress;
    localAddress = containerAddress;
    nixpkgs = matrixNixpkgs;

    bindMounts = lib.listToAttrs (
      map (b: {
        name = b.container;
        value = {
          hostPath = b.host;
          isReadOnly = false;
        };
      }) binds
    );

    config =
      { config, pkgs, ... }:
      {
        system.stateVersion = "24.11";

        # Allow olm - required by mautrix bridges. The security issues are
        # side-channel attacks on E2EE crypto, but SMS/RCS isn't E2EE through
        # the bridge anyway, and Signal E2EE is handled on Signal's side.
        nixpkgs.config.permittedInsecurePackages = [
          "olm-3.2.16"
        ];

        networking = {
          firewall = {
            enable = true;
            allowedTCPPorts = [
              8008 # Synapse Matrix API
              80 # Element Web (nginx)
            ];
          };
          useHostResolvConf = lib.mkForce false;
        };

        services.resolved.enable = true;

        # PostgreSQL for Synapse and mautrix bridges
        services.postgresql = {
          enable = true;
          package = pkgs.postgresql_17;
          ensureDatabases = [
            "matrix-synapse"
          ]
          ++ lib.optionals enableGmessages [ "mautrix_gmessages" ]
          ++ lib.optionals enableSignal [ "mautrix-signal" ]
          ++ lib.optionals enableInstagram [ "mautrix-meta-instagram" ]
          ++ lib.optionals enableFacebook [ "mautrix-meta-facebook" ]
          ++ lib.optionals enableWhatsapp [ "mautrix-whatsapp" ]
          ++ lib.optionals enableDiscord [ "mautrix-discord" ]
          ++ lib.optionals enableTelegram [ "mautrix-telegram" ];
          ensureUsers = [
            {
              name = "matrix-synapse";
              ensureDBOwnership = true;
            }
          ]
          ++ lib.optionals enableGmessages [{ name = "mautrix_gmessages"; ensureDBOwnership = true; }]
          ++ lib.optionals enableSignal [{ name = "mautrix-signal"; ensureDBOwnership = true; }]
          ++ lib.optionals enableInstagram [{ name = "mautrix-meta-instagram"; ensureDBOwnership = true; }]
          ++ lib.optionals enableFacebook [{ name = "mautrix-meta-facebook"; ensureDBOwnership = true; }]
          ++ lib.optionals enableWhatsapp [{ name = "mautrix-whatsapp"; ensureDBOwnership = true; }]
          ++ lib.optionals enableDiscord [{ name = "mautrix-discord"; ensureDBOwnership = true; }]
          ++ lib.optionals enableTelegram [{ name = "mautrix-telegram"; ensureDBOwnership = true; }];
          # Only allow local connections - no network access
          enableTCPIP = false;
          authentication = ''
            local all all peer
          '';
          # Synapse requires C locale for proper text sorting
          initdbArgs = [
            "--encoding=UTF8"
            "--lc-collate=C"
            "--lc-ctype=C"
          ];
        };

        # PostgreSQL backup
        services.postgresqlBackup = {
          enable = true;
          databases = [
            "matrix-synapse"
          ]
          ++ lib.optionals enableGmessages [ "mautrix_gmessages" ]
          ++ lib.optionals enableSignal [ "mautrix-signal" ]
          ++ lib.optionals enableInstagram [ "mautrix-meta-instagram" ]
          ++ lib.optionals enableFacebook [ "mautrix-meta-facebook" ]
          ++ lib.optionals enableWhatsapp [ "mautrix-whatsapp" ]
          ++ lib.optionals enableDiscord [ "mautrix-discord" ]
          ++ lib.optionals enableTelegram [ "mautrix-telegram" ];
        };

        # Synapse Matrix homeserver
        services.matrix-synapse = {
          enable = true;

          settings = {
            server_name = serverName;
            public_baseurl = "https://${serverName}";

            # Listeners - client only, no federation
            listeners = [
              {
                port = 8008;
                bind_addresses = [ "0.0.0.0" ];
                type = "http";
                tls = false;
                x_forwarded = true;
                resources = [
                  {
                    names = [ "client" ];
                    compress = true;
                  }
                ];
              }
            ];

            # Database
            database = {
              name = "psycopg2";
              args = {
                database = "matrix-synapse";
                user = "matrix-synapse";
              };
            };

            # Security: Disable federation completely
            federation_domain_whitelist = [ ];

            # Security: Disable registration and guest access
            enable_registration = false;
            allow_guest_access = false;

            # No stats reporting
            report_stats = false;

            # No trusted key servers needed without federation
            trusted_key_servers = [ ];

            # Disable presence to save resources on single-user server
            presence.enabled = false;

            # Rate limiting - exempt local users and the bridge bot.
            # This is a private single-user server so default rate limits
            # just get in the way (especially when the bridge creates many
            # rooms during initial sync).
            rc_joins = {
              local = { per_second = 100; burst_count = 200; };
              remote = { per_second = 100; burst_count = 200; };
            };
            rc_messages = { per_second = 100; burst_count = 200; };
            rc_login = {
              address = { per_second = 100; burst_count = 200; };
              account = { per_second = 100; burst_count = 200; };
              failed_attempts = { per_second = 100; burst_count = 200; };
            };

            # Media config
            max_upload_size = "50M";

            # App services (bridges) — only gmessages needs manual registration;
            # others use registerToSynapse which adds their files automatically.
            app_service_config_files =
              lib.optionals enableGmessages [ "/var/lib/mautrix_gmessages/registration.yaml" ];

            # URL previews
            url_preview_enabled = true;
            url_preview_ip_range_blacklist = [
              "127.0.0.0/8"
              "10.0.0.0/8"
              "172.16.0.0/12"
              "192.168.0.0/16"
              "100.64.0.0/10"
              "169.254.0.0/16"
              "::1/128"
              "fe80::/10"
              "fc00::/7"
            ];
          };

          # Secrets file (registration_shared_secret) - kept outside nix store
          extraConfigFiles = [
            "/var/lib/matrix-synapse/secrets.yaml"
          ];
        };

        # Ensure Synapse waits for gmessages bridge registration and has access.
        # All other bridges (signal, meta, whatsapp, discord, telegram) handle
        # their own Synapse integration automatically via registerToSynapse —
        # adds registration files, SupplementaryGroups, and service dependencies.
        systemd.services.matrix-synapse = lib.mkIf enableGmessages {
          after = [ "mautrix-gmessages-init.service" ];
          wants = [ "mautrix-gmessages-init.service" ];
          serviceConfig = {
            SupplementaryGroups = [ "mautrix_gmessages" ];
          };
        };

        # Generate Synapse secrets file if it doesn't exist
        systemd.services.synapse-secrets-init = {
          description = "Generate Synapse secrets";
          wantedBy = [ "matrix-synapse.service" ];
          before = [ "matrix-synapse.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            SECRETS_FILE="/var/lib/matrix-synapse/secrets.yaml"
            if [ ! -f "$SECRETS_FILE" ]; then
              SECRET=$(${pkgs.openssl}/bin/openssl rand -hex 32)
              MACAROON=$(${pkgs.openssl}/bin/openssl rand -hex 32)
              cat > "$SECRETS_FILE" <<EOF
            registration_shared_secret: "$SECRET"
            macaroon_secret_key: "$MACAROON"
            EOF
              chown matrix-synapse:matrix-synapse "$SECRETS_FILE"
              chmod 600 "$SECRETS_FILE"
            fi
          '';
        };

        # mautrix-gmessages bridge (manual service - no NixOS module exists)
        systemd.services.mautrix-gmessages = lib.mkIf enableGmessages {
          description = "mautrix-gmessages Matrix-Google Messages bridge";
          after = [
            "network.target"
            "matrix-synapse.service"
            "postgresql.service"
            "mautrix-gmessages-init.service"
          ];
          requires = [ "postgresql.service" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "simple";
            User = "mautrix_gmessages";
            Group = "mautrix_gmessages";
            ExecStart = "${pkgs.mautrix-gmessages}/bin/mautrix-gmessages -c /var/lib/mautrix_gmessages/config.yaml";
            Restart = "on-failure";
            RestartSec = "10s";

            # Security hardening
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ReadWritePaths = [ "/var/lib/mautrix_gmessages" ];
          };
        };

        # Generate mautrix-gmessages config if it doesn't exist
        systemd.services.mautrix-gmessages-init = lib.mkIf enableGmessages {
          description = "Initialize mautrix-gmessages configuration";
          wantedBy = [ "mautrix-gmessages.service" ];
          before = [
            "mautrix-gmessages.service"
            "matrix-synapse.service"
          ];
          after = [ "postgresql.service" ];
          requires = [ "postgresql.service" ];

          serviceConfig = {
            Type = "oneshot";
            User = "mautrix_gmessages";
            Group = "mautrix_gmessages";
            RemainAfterExit = true;
          };

          script = ''
            CONFIG_DIR="/var/lib/mautrix_gmessages"
            CONFIG_FILE="$CONFIG_DIR/config.yaml"
            REG_FILE="$CONFIG_DIR/registration.yaml"

            # Generate example config if none exists
            # -e = generate example config, -c = config path
            if [ ! -f "$CONFIG_FILE" ]; then
              ${pkgs.mautrix-gmessages}/bin/mautrix-gmessages -e -c "$CONFIG_FILE"

              # Patch the generated config with our settings using bridgev2 field paths
              ${pkgs.yq-go}/bin/yq -i '
                .homeserver.address = "http://localhost:8008" |
                .homeserver.domain = "${serverName}" |
                .database.type = "postgres" |
                .database.uri = "postgresql:///mautrix_gmessages?host=/run/postgresql" |
                .appservice.hostname = "127.0.0.1" |
                .appservice.port = 29336 |
                .appservice.id = "gmessages" |
                .appservice.bot.username = "gmessagesbot" |
                .appservice.bot.displayname = "Google Messages Bridge" |
                .bridge.permissions."${serverName}" = "user" |
                .bridge.permissions."@josh:${serverName}" = "admin" |
                .bridge.delivery_receipts = true |
                .bridge.sync_direct_chat_list = true |
                .logging.min_level = "warn" |
                .logging.writers = [{"type": "stdout", "format": "pretty-colored"}] |
                .network.initial_chat_sync_count = 99999
              ' "$CONFIG_FILE"
            fi

            # Ensure settings that may have been added after initial config generation
            ${pkgs.yq-go}/bin/yq -i '
              .network.initial_chat_sync_count = 99999
            ' "$CONFIG_FILE"

            # Generate registration file if none exists
            # -g = generate registration, -c = config path, -r = registration output path
            # This also writes AS/HS tokens back into config.yaml
            if [ ! -f "$REG_FILE" ]; then
              ${pkgs.mautrix-gmessages}/bin/mautrix-gmessages -g -c "$CONFIG_FILE" -r "$REG_FILE"
              chmod 640 "$REG_FILE"
            fi

            # Ensure registration allows the appservice to masquerade as Josh.
            # The default namespace only matches @gmessages_.* which blocks
            # impersonation for backfill/sent-message injection.
            if ! ${pkgs.yq-go}/bin/yq -e '.namespaces.users[] | select(.regex == "@josh:${lib.strings.escape ["."] serverName}")' "$REG_FILE" > /dev/null 2>&1; then
              ${pkgs.yq-go}/bin/yq -i '
                .namespaces.users += [{"regex": "@josh:${lib.strings.escape ["."] serverName}", "exclusive": false}]
              ' "$REG_FILE"
            fi
          '';
        };

        # Create user/group for mautrix_gmessages
        users.users.mautrix_gmessages = lib.mkIf enableGmessages {
          isSystemUser = true;
          group = "mautrix_gmessages";
          home = "/var/lib/mautrix_gmessages";
          uid = 992;
        };

        users.groups.mautrix_gmessages = lib.mkIf enableGmessages {
          gid = 992;
        };

        # mautrix-signal bridge (uses NixOS module — handles registration,
        # Synapse integration, config generation, and systemd service)
        services.mautrix-signal = {
          enable = enableSignal;
          serviceDependencies = [
            "matrix-synapse.service"
            "postgresql.service"
          ];

          settings = {
            homeserver.address = "http://localhost:8008";
            homeserver.domain = serverName;

            database = {
              type = "postgres";
              uri = "postgresql:///mautrix-signal?host=/run/postgresql";
            };

            appservice = {
              hostname = "127.0.0.1";
              port = 29328;
            };

            bridge = {
              permissions = {
                "${serverName}" = "user";
                "@josh:${serverName}" = "admin";
              };
              relay.enabled = false;
            };

            backfill.enabled = true;

            logging = {
              min_level = "warn";
              writers = [
                {
                  type = "stdout";
                  format = "pretty-colored";
                }
              ];
            };
          };
        };

        # Fix uid/gid for mautrix-signal user — the NixOS module auto-creates
        # the user but with auto-assigned uid. We need stable ids for the bind
        # mount from the host.
        users.users.mautrix-signal = lib.mkIf enableSignal {
          uid = lib.mkForce 991;
        };

        users.groups.mautrix-signal = lib.mkIf enableSignal {
          gid = lib.mkForce 991;
        };

        # mautrix-meta bridges (Instagram + Facebook Messenger)
        # Uses multi-instance design: services.mautrix-meta.instances.<name>
        # Pre-configured "instagram" and "facebook" instances with sane defaults.
        # registerToSynapse handles appservice registration automatically.
        services.mautrix-meta.instances = {
          instagram = {
            enable = enableInstagram;
            serviceDependencies = [
              "matrix-synapse.service"
              "postgresql.service"
            ];

            settings = {
              homeserver.address = "http://localhost:8008";
              homeserver.domain = serverName;

              database = {
                type = "postgres";
                uri = "postgresql:///mautrix-meta-instagram?host=/run/postgresql";
              };

              appservice = {
                hostname = "127.0.0.1";
                port = 29320;
                id = "meta-instagram";
                bot.username = "instagrambot";
                bot.displayname = "Instagram Bridge";
              };

              bridge = {
                permissions = {
                  "${serverName}" = "user";
                  "@josh:${serverName}" = "admin";
                };
              };

              network.mode = "instagram";

              logging = {
                min_level = "warn";
                writers = [
                  {
                    type = "stdout";
                    format = "pretty-colored";
                  }
                ];
              };
            };
          };

          facebook = {
            enable = enableFacebook;
            serviceDependencies = [
              "matrix-synapse.service"
              "postgresql.service"
            ];

            settings = {
              homeserver.address = "http://localhost:8008";
              homeserver.domain = serverName;

              database = {
                type = "postgres";
                uri = "postgresql:///mautrix-meta-facebook?host=/run/postgresql";
              };

              appservice = {
                hostname = "127.0.0.1";
                port = 29321;
                id = "meta-facebook";
                bot.username = "facebookbot";
                bot.displayname = "Facebook Messenger Bridge";
              };

              bridge = {
                permissions = {
                  "${serverName}" = "user";
                  "@josh:${serverName}" = "admin";
                };
              };

              network.mode = "messenger";

              logging = {
                min_level = "warn";
                writers = [
                  {
                    type = "stdout";
                    format = "pretty-colored";
                  }
                ];
              };
            };
          };
        };

        # Fix uid/gid for mautrix-meta users — the NixOS module auto-creates
        # per-instance users with shared mautrix-meta group. We need stable ids
        # for the bind mounts from the host.
        users.users.mautrix-meta-instagram = lib.mkIf enableInstagram {
          uid = lib.mkForce 990;
        };
        users.users.mautrix-meta-facebook = lib.mkIf enableFacebook {
          uid = lib.mkForce 989;
        };
        users.groups.mautrix-meta = lib.mkIf (enableInstagram || enableFacebook) {
          gid = lib.mkForce 985;
        };

        # mautrix-whatsapp bridge
        services.mautrix-whatsapp = {
          enable = enableWhatsapp;
          serviceDependencies = [
            "matrix-synapse.service"
            "postgresql.service"
          ];

          settings = {
            homeserver.address = "http://localhost:8008";
            homeserver.domain = serverName;

            database = {
              type = "postgres";
              uri = "postgresql:///mautrix-whatsapp?host=/run/postgresql";
            };

            appservice = {
              hostname = "127.0.0.1";
              port = 29318;
              bot.username = "whatsappbot";
              bot.displayname = "WhatsApp Bridge";
            };

            bridge = {
              permissions = {
                "${serverName}" = "user";
                "@josh:${serverName}" = "admin";
              };
            };

            logging = {
              min_level = "warn";
              writers = [
                {
                  type = "stdout";
                  format = "pretty-colored";
                }
              ];
            };
          };
        };

        users.users.mautrix-whatsapp = lib.mkIf enableWhatsapp {
          uid = lib.mkForce 988;
        };
        users.groups.mautrix-whatsapp = lib.mkIf enableWhatsapp {
          gid = lib.mkForce 988;
        };

        # mautrix-discord bridge
        services.mautrix-discord = {
          enable = enableDiscord;
          serviceDependencies = [
            "matrix-synapse.service"
            "postgresql.service"
          ];

          settings = {
            homeserver = {
              address = "http://localhost:8008";
              domain = serverName;
            };

            appservice = {
              hostname = "127.0.0.1";
              port = 29334;
              bot = {
                username = "discordbot";
                displayname = "Discord Bridge";
              };
              database = {
                type = "postgres";
                uri = "postgresql:///mautrix-discord?host=/run/postgresql";
              };
            };

            bridge = {
              permissions = {
                "${serverName}" = "user";
                "@josh:${serverName}" = "admin";
              };
            };

            logging = {
              min_level = "warn";
              writers = [
                {
                  type = "stdout";
                  format = "pretty-colored";
                }
              ];
            };
          };
        };

        users.users.mautrix-discord = lib.mkIf enableDiscord {
          uid = lib.mkForce 987;
        };
        users.groups.mautrix-discord = lib.mkIf enableDiscord {
          gid = lib.mkForce 987;
        };

        # mautrix-telegram bridge (Python-based, different config format)
        # Uses SQLAlchemy-style connection strings instead of type/uri objects.
        # Requires Telegram API keys — defaults from mautrix-telegram are used.
        services.mautrix-telegram = {
          enable = enableTelegram;
          serviceDependencies = [
            "matrix-synapse.service"
            "postgresql.service"
          ];

          settings = {
            homeserver = {
              address = "http://localhost:8008";
              domain = serverName;
            };

            appservice = {
              hostname = "127.0.0.1";
              port = 29317;
              database = "postgresql:///mautrix-telegram?host=/run/postgresql";
              bot_username = "telegrambot";
              bot_displayname = "Telegram Bridge";
            };

            bridge = {
              permissions = {
                "${serverName}" = "full";
                "@josh:${serverName}" = "admin";
              };
              # Telegram bridge uses "full" instead of "user" for regular access
              # (relaybot, user, full, admin are the permission levels)
            };
          };
        };

        users.users.mautrix-telegram = lib.mkIf enableTelegram {
          uid = lib.mkForce 986;
        };
        users.groups.mautrix-telegram = lib.mkIf enableTelegram {
          gid = lib.mkForce 986;
        };

        # nginx inside container for Element Web
        services.nginx = {
          enable = true;
          virtualHosts."element" = {
            listen = [
              {
                addr = "0.0.0.0";
                port = 80;
              }
            ];
            root = elementWebCustom;
            locations."/" = {
              tryFiles = "$uri $uri/ /index.html";
            };
          };
        };

        # Ensure directories exist with proper permissions
        systemd.tmpfiles.rules = [
          "d /var/lib/matrix-synapse 0750 matrix-synapse matrix-synapse -"
        ]
        ++ lib.optionals enableGmessages [ "d /var/lib/mautrix_gmessages 0750 mautrix_gmessages mautrix_gmessages -" ]
        ++ lib.optionals enableSignal [ "d /var/lib/mautrix-signal 0750 mautrix-signal mautrix-signal -" ]
        ++ lib.optionals enableInstagram [ "d /var/lib/mautrix-meta-instagram 0750 mautrix-meta-instagram mautrix-meta -" ]
        ++ lib.optionals enableFacebook [ "d /var/lib/mautrix-meta-facebook 0750 mautrix-meta-facebook mautrix-meta -" ]
        ++ lib.optionals enableWhatsapp [ "d /var/lib/mautrix-whatsapp 0750 mautrix-whatsapp mautrix-whatsapp -" ]
        ++ lib.optionals enableDiscord [ "d /var/lib/mautrix-discord 0750 mautrix-discord mautrix-discord -" ]
        ++ lib.optionals enableTelegram [ "d /var/lib/mautrix-telegram 0750 mautrix-telegram mautrix-telegram -" ];
      };
  };
}
