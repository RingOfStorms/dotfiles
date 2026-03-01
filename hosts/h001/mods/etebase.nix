{
  config,
  pkgs,
  constants,
  ...
}:
let
  c = constants.services.etebase;
  socketPath = "/run/etebase-server/etebase-server.sock";

  # EteSync Web - static SPA for calendar/contacts
  etesyncWebSrc = pkgs.fetchzip {
    url = "https://pim.etesync.com/etesync-web.tgz";
    hash = "sha256-I6rbDAklznByAYtslBT0gGGbZXaGzrtX7WpC0Wh8Qxk=";
  };

  # Patch the default API URL in the JS bundle at build time so the app
  # points at our self-hosted etebase instance without manual configuration.
  defaultApiUrl = "https://api.etebase.com/partner/etesync/";
  selfHostedApiUrl = "https://${c.domain}/";

  etesyncWeb = pkgs.runCommand "etesync-web-patched" { } ''
    cp -r ${etesyncWebSrc} $out
    chmod -R u+w $out
    for jsFile in $out/static/js/*.js; do
      substituteInPlace "$jsFile" \
        --replace-quiet '${defaultApiUrl}' '${selfHostedApiUrl}'
    done
  '';
in
{
  # Generate a secret file for Django's SECRET_KEY if it doesn't exist
  systemd.services.etebase-server-secret = {
    description = "Generate Etebase server secret";
    wantedBy = [ "etebase-server.service" ];
    before = [ "etebase-server.service" ];
    unitConfig.ConditionPathExists = "!${c.dataDir}/secret.txt";
    serviceConfig = {
      Type = "oneshot";
      User = "etebase-server";
      Group = "etebase-server";
      UMask = "0077";
    };
    script = ''
      ${pkgs.openssl}/bin/openssl rand -base64 64 | tr -d '\n' > ${c.dataDir}/secret.txt
      chmod 600 ${c.dataDir}/secret.txt
    '';
  };

  # Ensure the etebase-server user/group exist before secret generation
  users.users.etebase-server = {
    isSystemUser = true;
    group = "etebase-server";
    home = c.dataDir;
  };
  users.groups.etebase-server = { };

  # Pre-create data directory with correct permissions
  systemd.tmpfiles.rules = [
    "d '${c.dataDir}' 0750 etebase-server etebase-server - -"
  ];

  services.etebase-server = {
    enable = true;
    # Use Unix socket for better security (nginx connects via socket, not TCP)
    unixSocket = socketPath;
    settings = {
      global = {
        debug = false;
        secret_file = "${c.dataDir}/secret.txt";
        static_root = "${c.dataDir}/static";
        media_root = "${c.dataDir}/media";
      };
      allowed_hosts = {
        allowed_host1 = c.domain;
      };
    };
  };

  services.nginx.virtualHosts = {
    "${c.domain}" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
      locations = {
        # Serve static files directly via nginx (better performance)
        "/static/" = {
          alias = "${c.dataDir}/static/";
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
    # JS bundle is patched at build time to default to our etebase instance.
    "${c.webDomain}" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
      root = etesyncWeb;
      locations = {
        "/" = {
          tryFiles = "$uri $uri/ /index.html";
        };
      };
    };
  };

  # Allow nginx to access the etebase socket
  users.users.nginx.extraGroups = [ "etebase-server" ];
}
