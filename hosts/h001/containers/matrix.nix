# SETUP
# 1. Rebuild and wait for container to start
# 2. Create accounts:
#    sudo nixos-container run matrix -- register_new_matrix_user -c /var/lib/matrix-synapse/secrets.yaml http://localhost:8008 -u admin -p <password> -a
#    sudo nixos-container run matrix -- register_new_matrix_user -c /var/lib/matrix-synapse/secrets.yaml http://localhost:8008 -u josh -p <password> --no-admin
# 3. Login at https://element.joshuabell.xyz
# 4. DM @gmessagesbot:matrix.joshuabell.xyz and send "login" to pair Google Messages
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

  # Bind mount definitions following forgejo.nix pattern
  binds = [
    {
      host = "${hostDataDir}/postgres";
      container = "/var/lib/postgresql/17";
      user = "postgres";
      uid = 71;
      gid = 71;
    }
    {
      host = "${hostDataDir}/backups";
      container = "/var/backup/postgresql";
      user = "postgres";
      uid = 71;
      gid = 71;
    }
    {
      host = "${hostDataDir}/synapse";
      container = "/var/lib/matrix-synapse";
      user = "matrix-synapse";
      uid = 198;
      gid = 198;
    }
    {
      host = "${hostDataDir}/gmessages";
      container = "/var/lib/mautrix_gmessages";
      user = "mautrix_gmessages";
      uid = 992;
      gid = 992;
    }
  ];

  uniqueUsers = lib.unique (map (b: { inherit (b) user uid gid; }) binds);

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
        group = u.user;
      };
    }) (lib.filter (u: u.user != "postgres") uniqueUsers)
  );

  users.groups = lib.listToAttrs (
    map (u: {
      name = u.user;
      value = {
        gid = u.gid;
      };
    }) (lib.filter (u: u.user != "postgres") uniqueUsers)
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

        # Allow olm - required by mautrix-gmessages. The security issues are
        # side-channel attacks on E2EE crypto, but SMS/RCS isn't E2EE through
        # the bridge anyway (RCS encryption is handled by Google Messages).
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

        # PostgreSQL for Synapse and mautrix-gmessages
        services.postgresql = {
          enable = true;
          package = pkgs.postgresql_17;
          ensureDatabases = [
            "matrix-synapse"
            "mautrix_gmessages"
          ];
          ensureUsers = [
            {
              name = "matrix-synapse";
              ensureDBOwnership = true;
            }
            {
              name = "mautrix_gmessages";
              ensureDBOwnership = true;
            }
          ];
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
            "mautrix_gmessages"
          ];
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

            # Media config
            max_upload_size = "50M";

            # App services (bridges)
            app_service_config_files = [
              "/var/lib/mautrix_gmessages/registration.yaml"
            ];

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

        # Ensure Synapse waits for bridge registration and has access to it
        systemd.services.matrix-synapse = {
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
        systemd.services.mautrix-gmessages = {
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
        systemd.services.mautrix-gmessages-init = {
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
        users.users.mautrix_gmessages = {
          isSystemUser = true;
          group = "mautrix_gmessages";
          home = "/var/lib/mautrix_gmessages";
          uid = 992;
        };

        users.groups.mautrix_gmessages = {
          gid = 992;
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
          "d /var/lib/mautrix_gmessages 0750 mautrix_gmessages mautrix_gmessages -"
        ];
      };
  };
}
