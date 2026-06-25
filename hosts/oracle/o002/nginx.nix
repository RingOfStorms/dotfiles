{
  config,
  constants,
  fleet,
  ...
}:
let
  c = constants;
  domain = fleet.global.domain;
  upstream = c.upstreamHost;

  # All public vhosts proxy to h001 over the tailnet. h001's own nginx
  # terminates per-service and forwards to the right container.
  proxyToUpstream = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyWebsockets = true;
      proxyPass = "http://${upstream}";
    };
  };
in
{
  # nginx proxies to tailscale overlay IPs and binds on overlayIp.
  # tailscaled-autoconnect.service (Type=notify) only finishes once `tailscale up`
  # has returned and tailscale0 has its address; tailscaled.service alone is just
  # the daemon being started and races nginx's bind. IPFreeBind=true also lets
  # nginx bind to addresses not yet on any interface as belt-and-suspenders.
  systemd.services.nginx = {
    wants = [ "network-online.target" "tailscaled-autoconnect.service" ];
    after = [ "network-online.target" "tailscaled-autoconnect.service" ];
    serviceConfig.IPFreeBind = true;
  };

  security.acme.acceptTerms = true;
  security.acme.defaults.email = fleet.global.acmeEmail;
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    clientMaxBodySize = "500m";
    commonHttpConfig = ''
      log_format noauth '$remote_addr - $remote_user [$time_local] '
                        '"$request" $status $body_bytes_sent '
                        '"$http_referer" "$http_user_agent"';
    '';
    virtualHosts =
      let
        tailnetConfig = {
          locations = {
            "/" = {
              extraConfig = ''
                default_type text/html;
                return 200 '
                  <html>
                    jRmvVcy0mlTrVJGiPMHsiCF6pQ2JCDNe2LiYJwcwgm8=
                  </html>
                ';
              '';
            };
          };
        };
      in
      {
        # Redirect self IP to domain
        "${c.host.publicIp}" = {
          locations."/" = {
            return = "301 https://${domain}";
          };
        };

        "${c.host.overlayIp}" = tailnetConfig;
        "o002.net.${domain}" = tailnetConfig;

        "www.${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            return = "301 https://${domain}";
          };
        };
        "${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations = {
            "/" = {
              extraConfig = ''
                default_type text/html;
                return 200 '
                  <html>
                    <body style="width:100vw;height:100vh;overflow:hidden">
                      <div style="display: flex;width:100vw;height:100vh;justify-content: center;align-items:center;text-align:center;overflow:hidden">
                        In the void you roam,</br>
                        A page that cannot be found-</br>
                        Turn back, seek anew.
                      </div>
                    </body>
                  </html>
                ';
              '';
            };
          };
        };

        "www.ellalala.com" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            return = "301 https://ellalala.com";
          };
        };
        "ellalala.com" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            return = "444";
          };
        };

        # ── Services migrated off o001 onto h001 (proxied over tailnet) ──
        "vault.${domain}" = proxyToUpstream;
        "atuin.${domain}" = proxyToUpstream;

        # PROXY HOSTS (all forwarded to h001 over the tailnet)
        "chat.${domain}" = proxyToUpstream;
        "gist.${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://${upstream}";
          };
        };
        "git.${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://${upstream}";
          };
        };
        "n8n.${domain}" = proxyToUpstream;
        "notes.${domain}" = proxyToUpstream;
        "sec.${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://${upstream}";
          };
        };
        "sso.${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://${upstream}";
            extraConfig = ''
              proxy_set_header X-Forwarded-Proto https;
            '';
          };
        };
        "sso-proxy.${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://${upstream}";
            extraConfig = ''
              proxy_set_header X-Forwarded-Proto https;
            '';
          };
        };
        "jellyfin.${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://${upstream}";
          };
        };
        "media.${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://${upstream}";
          };
        };
        "puzzles.${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://${upstream}";
          };
        };
        "etebase.${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://${upstream}";
            extraConfig = ''
              client_max_body_size 75M;
            '';
          };
        };
        "pim.${domain}" = proxyToUpstream;
        "location.${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://${upstream}";
            extraConfig = ''
              client_max_body_size 50G;
            '';
          };
        };
        "photos.${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://${upstream}";
            extraConfig = ''
              client_max_body_size 100G;
            '';
          };
        };
        # Matrix homeserver — proxy to h001's host nginx which handles
        # container forwarding. Needs .well-known endpoints for client
        # discovery and large body size for media uploads.
        "matrix.${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://${upstream}";
            proxyWebsockets = true;
            extraConfig = ''
              proxy_read_timeout 600s;
              client_max_body_size 50M;
            '';
          };
        };

        # Element Web client for Matrix
        "element.${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://${upstream}";
            proxyWebsockets = true;
          };
        };

        # ── Minecraft survival map (squaremap) ─────────────────────────────
        # Proxied to h003's nginx over tailscale, which proxies to squaremap
        "computerboyz.${domain}" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            return = "444";
          };
          locations."/map/survival/" = {
            proxyPass = "http://${fleet.hosts.h003.overlayIp}:80/map/survival/";
            proxyWebsockets = true;
          };
        };

        "_" = {
          rejectSSL = true;
          default = true;
          locations."/" = {
            return = "444"; # 404 for not found or 444 for drop
          };
        };
      };

    # STREAMS
    streamConfig = ''
      server {
        listen 3032;
        proxy_pass ${upstream}:3032;
      }
    '';
  };

  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
    ignoreIP = [
      "127.0.0.1/8"
      "24.16.158.91" # Jason's ip
      "98.193.92.231" # my ip
      "24.164.16.22" # aarons ip
    ];
    bantime-increment = {
      enable = true;
      maxtime = "168h";
      factor = "4";
    };
  };

  # NOTE Oracle also has security rules that must expose these ports so this
  # alone will not work! See hosts/oracle/readme.md
  networking.firewall.allowedTCPPorts = [
    80 # web http
    443 # web https
    3032 # ssh for git server
  ];
}
