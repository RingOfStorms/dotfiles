{
  config,
  lib,
  pkgs,
  constants,
  fleet,
  ...
}:
let
  c = constants;
  domain = fleet.global.domain;
  upstream = c.upstreamHost;

  # Public `via = edge` routes of floating containers (ROUTING-PLAN §2.3,
  # §8 step 3), generated from containers/*/service.nix. Each proxies to the
  # service host's edge listener (<overlayIp>:8443).
  containersLib = import ../../../containers/lib.nix;
  containerVhosts = containersLib.edgeVirtualHosts {
    dir = ../../../containers;
    inherit (fleet) hosts;
  };

  # TLS (ROUTING-PLAN §8 step 4): names listed here serve the
  # *.joshuabell.xyz + apex wildcard that h005 issues and pushes
  # (hosts/wildcard-cert-receiver.nix) instead of their own http-01 cert.
  # Moved over one name at a time; "all" switches every joshuabell.xyz
  # vhost.
  wildcardNames = [ "all" ];
  coveredByWildcard =
    name:
    name == domain
    || (lib.hasSuffix ".${domain}" name && !lib.hasInfix "." (lib.removeSuffix ".${domain}" name));
  useWildcard =
    name: coveredByWildcard name && (wildcardNames == [ "all" ] || builtins.elem name wildcardNames);
  withTls =
    name: v:
    if useWildcard name then builtins.removeAttrs v [ "enableACME" ] // config.fleet.wildcardTls else v;
in
{
  # nginx proxies to tailscale overlay IPs and binds on overlayIp.
  # tailscaled-autoconnect.service (Type=notify) only finishes once `tailscale up`
  # has returned and tailscale0 has its address; tailscaled.service alone is just
  # the daemon being started and races nginx's bind. IPFreeBind=true also lets
  # nginx bind to addresses not yet on any interface as belt-and-suspenders.
  systemd.services.nginx = {
    wants = [
      "network-online.target"
      "tailscaled-autoconnect.service"
    ];
    after = [
      "network-online.target"
      "tailscaled-autoconnect.service"
    ];
    serviceConfig.IPFreeBind = true;
  };

  security.acme.acceptTerms = true;
  security.acme.defaults.email = fleet.global.acmeEmail;
  services.nginx = {
    enable = true;
    # njs module: removed — was only used by the OpenBao JWT gate.
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
        handVhosts = {
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

          # ── Headscale coordination server (runs locally on o002) ──
          # Proxy to 127.0.0.1 (not localhost) — headscale binds IPv4 only, and
          # nginx resolving localhost to [::1] gives connection-refused.
          "headscale.${domain}" = {
            enableACME = true;
            forceSSL = true;
            locations."/" = {
              proxyWebsockets = true;
              proxyPass = "http://127.0.0.1:${toString constants.services.headscale.port}";
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
        clash = builtins.attrNames (builtins.intersectAttrs handVhosts containerVhosts);
      in
      assert lib.assertMsg (
        clash == [ ]
      ) "o002 nginx: ${toString clash} is both hand-kept and generated from containers routes";
      lib.mapAttrs withTls (handVhosts // containerVhosts);

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
