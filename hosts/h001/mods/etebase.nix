{
  config,
  pkgs,
  ...
}:
let
  dataDir = "/var/lib/etebase-server";
  socketPath = "/run/etebase-server/etebase-server.sock";

  # EteSync Web - static SPA for calendar/contacts
  etesyncWeb = pkgs.fetchzip {
    url = "https://pim.etesync.com/etesync-web.tgz";
    hash = "sha256-I6rbDAklznByAYtslBT0gGGbZXaGzrtX7WpC0Wh8Qxk=";
  };
in
{
  # Generate a secret file for Django's SECRET_KEY if it doesn't exist
  systemd.services.etebase-server-secret = {
    description = "Generate Etebase server secret";
    wantedBy = [ "etebase-server.service" ];
    before = [ "etebase-server.service" ];
    unitConfig.ConditionPathExists = "!${dataDir}/secret.txt";
    serviceConfig = {
      Type = "oneshot";
      User = "etebase-server";
      Group = "etebase-server";
      UMask = "0077";
    };
    script = ''
      ${pkgs.openssl}/bin/openssl rand -base64 64 | tr -d '\n' > ${dataDir}/secret.txt
      chmod 600 ${dataDir}/secret.txt
    '';
  };

  # Ensure the etebase-server user/group exist before secret generation
  users.users.etebase-server = {
    isSystemUser = true;
    group = "etebase-server";
    home = dataDir;
  };
  users.groups.etebase-server = { };

  # Pre-create data directory with correct permissions
  systemd.tmpfiles.rules = [
    "d '${dataDir}' 0750 etebase-server etebase-server - -"
  ];

  services.etebase-server = {
    enable = true;
    # Use Unix socket for better security (nginx connects via socket, not TCP)
    unixSocket = socketPath;
    settings = {
      global = {
        debug = false;
        secret_file = "${dataDir}/secret.txt";
        static_root = "${dataDir}/static";
        media_root = "${dataDir}/media";
      };
      allowed_hosts = {
        allowed_host1 = "etebase.joshuabell.xyz";
      };
    };
  };

  services.nginx.virtualHosts = {
    "etebase.joshuabell.xyz" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
      locations = {
        # Serve static files directly via nginx (better performance)
        "/static/" = {
          alias = "${dataDir}/static/";
          extraConfig = ''
            expires 30d;
            add_header Cache-Control "public, immutable";
          '';
        };
        # Proxy everything else to the etebase server via Unix socket
        "/" = {
          proxyPass = "http://unix:${socketPath}";
          proxyWebsockets = true;
          recommendedProxySettings = true;
          extraConfig = ''
            client_max_body_size 75M;
          '';
        };
      };
    };

    # EteSync Web - static SPA for calendar/contacts management
    # Rewrites the default API URL in the JS bundle so users don't need
    # to toggle advanced settings and manually enter the server URL.
    "pim.joshuabell.xyz" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
      root = etesyncWeb;
      locations = {
        "/" = {
          tryFiles = "$uri $uri/ /index.html";
        };
        # Rewrite the hardcoded default API URL in JS chunks to point
        # at our self-hosted etebase instance instead.
        "~* \\.js$" = {
          extraConfig = ''
            sub_filter 'https://api.etebase.com/partner/etesync/' 'https://etebase.joshuabell.xyz/';
            sub_filter_once on;
            sub_filter_types application/javascript;
          '';
        };
      };
    };
  };

  # Allow nginx to access the etebase socket
  users.users.nginx.extraGroups = [ "etebase-server" ];
}
