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

  # Use unstable nixpkgs for the container (mautrix-gmessages module not in stable)
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
      host = "${hostDataDir}/dendrite";
      container = "/var/lib/dendrite";
      user = "dendrite";
      uid = 993;
      gid = 993;
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
    # Matrix server - handles client and federation API
    "${serverName}" = {
      forceSSL = true;
      useACMEHost = "joshuabell.xyz";

      # .well-known for Matrix federation discovery
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

      # Matrix client and federation API
      locations."/_matrix" = {
        proxyPass = "http://${containerAddress}:8008";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_read_timeout 600s;
          client_max_body_size 50M;
        '';
      };

      # Dendrite admin API (only accessible internally)
      locations."/_dendrite" = {
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
              8008 # Dendrite Matrix API
              80 # Element Web (nginx)
            ];
          };
          useHostResolvConf = lib.mkForce false;
        };

        services.resolved.enable = true;

        # Add dendrite to PATH for admin tools (create-account, etc.)
        environment.systemPackages = [ pkgs.dendrite ];

        # PostgreSQL for Dendrite and mautrix-gmessages
        services.postgresql = {
          enable = true;
          package = pkgs.postgresql_17;
          ensureDatabases = [
            "dendrite"
            "mautrix_gmessages"
          ];
          ensureUsers = [
            {
              name = "dendrite";
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
        };

        # PostgreSQL backup
        services.postgresqlBackup = {
          enable = true;
          databases = [
            "dendrite"
            "mautrix_gmessages"
          ];
        };

        # Dendrite Matrix homeserver
        services.dendrite = {
          enable = true;
          httpPort = 8008;

          # Load signing key from file (generated on first boot)
          loadCredential = [ "signing_key:/var/lib/dendrite/matrix_key.pem" ];

          settings = {
            global = {
              server_name = serverName;
              private_key = "$CREDENTIALS_DIRECTORY/signing_key";

              # Security: Disable federation to keep messages private
              # Set to true if you want to chat with users on other Matrix servers
              disable_federation = true;

              database = {
                connection_string = "postgresql:///dendrite?host=/run/postgresql";
                max_open_conns = 50;
                max_idle_conns = 5;
                conn_max_lifetime = -1;
              };

              # Security: strict DNS caching
              dns_cache = {
                enabled = true;
                cache_size = 256;
                cache_lifetime = "5m";
              };
            };

            # Client API configuration
            client_api = {
              # Security: Disable registration - only admin can create accounts
              registration_disabled = true;

              # Security: Disable guest access
              guests_disabled = true;

              # Rate limiting
              rate_limiting = {
                enabled = true;
                threshold = 20;
                cooloff_ms = 500;
                exempt_user_ids = [ ];
              };
            };

            # Federation API - disabled for privacy
            federation_api = {
              # Security: No federation means messages stay on your server only
              disable_tls_validation = false;
              disable_http_keepalives = false;
              send_max_retries = 16;
              key_perspectives = [ ];
            };

            # Media API
            media_api = {
              base_path = "/var/lib/dendrite/media";
              max_file_size_bytes = 52428800; # 50MB
              dynamic_thumbnails = true;
            };

            # Sync API
            sync_api = {
              real_ip_header = "X-Forwarded-For";
              search = {
                enabled = true;
                index_path = "/var/lib/dendrite/searchindex";
              };
            };

            # User API
            user_api = {
              bcrypt_cost = 12; # Security: higher bcrypt cost
            };

            # MSCs (Matrix Spec Changes) - enable useful ones
            mscs = {
              mscs = [
                "msc2836" # Threading
                "msc2946" # Spaces
              ];
            };

            # Logging
            logging = [
              {
                type = "std";
                level = "warn";
              }
            ];

            # App services (bridges) - will be configured below
            app_service_api = {
              database = {
                connection_string = "postgresql:///dendrite?host=/run/postgresql";
                max_open_conns = 10;
                max_idle_conns = 2;
                conn_max_lifetime = -1;
              };
              config_files = [
                "/var/lib/mautrix_gmessages/registration.yaml"
              ];
            };
          };
        };

        # Generate Dendrite signing key if it doesn't exist
        systemd.services.dendrite-keygen = {
          description = "Generate Dendrite signing key";
          wantedBy = [ "dendrite.service" ];
          before = [ "dendrite.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = "dendrite";
            Group = "dendrite";
            RemainAfterExit = true;
          };
          script = ''
            if [ ! -f /var/lib/dendrite/matrix_key.pem ]; then
              ${pkgs.dendrite}/bin/generate-keys --private-key /var/lib/dendrite/matrix_key.pem
              chmod 600 /var/lib/dendrite/matrix_key.pem
            fi
          '';
        };

        # mautrix-gmessages bridge (manual service - no NixOS module exists)
        systemd.services.mautrix-gmessages = {
          description = "mautrix-gmessages Matrix-Google Messages bridge";
          after = [
            "network.target"
            "dendrite.service"
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
            StateDirectory = "mautrix_gmessages";
          };
        };

        # Generate mautrix-gmessages config if it doesn't exist
        systemd.services.mautrix-gmessages-init = {
          description = "Initialize mautrix-gmessages configuration";
          wantedBy = [ "mautrix-gmessages.service" ];
          before = [ "mautrix-gmessages.service" ];
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
            if [ ! -f "$CONFIG_FILE" ]; then
              ${pkgs.mautrix-gmessages}/bin/mautrix-gmessages -c "$CONFIG_FILE" -g

              # Patch the generated config with our settings
              ${pkgs.yq-go}/bin/yq -i '
                .homeserver.address = "http://localhost:8008" |
                .homeserver.domain = "${serverName}" |
                .appservice.database.type = "postgres" |
                .appservice.database.uri = "postgresql:///mautrix_gmessages?host=/run/postgresql" |
                .appservice.hostname = "127.0.0.1" |
                .appservice.port = 29336 |
                .appservice.id = "gmessages" |
                .appservice.bot.username = "gmessagesbot" |
                .appservice.bot.displayname = "Google Messages Bridge" |
                .bridge.permissions."${serverName}" = "user" |
                .bridge.permissions."@josh:${serverName}" = "admin" |
                .bridge.delivery_receipts = true |
                .bridge.sync_direct_chat_list = true |
                .logging.min_level = "warn"
              ' "$CONFIG_FILE"
            fi

            # Generate registration file if none exists
            if [ ! -f "$REG_FILE" ]; then
              ${pkgs.mautrix-gmessages}/bin/mautrix-gmessages -c "$CONFIG_FILE" -r "$REG_FILE"
              chmod 640 "$REG_FILE"
            fi
          '';
        };

        # Create user/group for mautrix_gmessages
        users.users.mautrix_gmessages = {
          isSystemUser = true;
          group = "mautrix_gmessages";
          home = "/var/lib/mautrix_gmessages";
        };

        users.groups.mautrix_gmessages = { };

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
          "d /var/lib/dendrite 0750 dendrite dendrite -"
          "d /var/lib/dendrite/media 0750 dendrite dendrite -"
          "d /var/lib/dendrite/searchindex 0750 dendrite dendrite -"
          "d /var/lib/mautrix_gmessages 0750 mautrix_gmessages mautrix_gmessages -"
        ];
      };
  };
}
