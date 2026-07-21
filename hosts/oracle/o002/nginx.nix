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

  # ── OpenBao (sec.) public-edge hardening ────────────────────────────
  # OpenBao is the fleet root-of-trust and MUST stay publicly reachable for
  # ONE reason only: a brand-new machine fetches its headscale join key
  # (`headscale_auth_*`) from OpenBao *before* it is on the tailnet. Once a
  # machine has joined, the headscale split-DNS for joshuabell.xyz (see
  # hosts/oracle/o002/headscale.nix -> h003's tailnet dnsmasq) resolves
  # `sec.joshuabell.xyz` to h001's overlay IP, so all steady-state traffic goes
  # over the tailnet and never touches this vhost.
  #
  # TWO layers protect this public edge:
  #
  #   Layer 1 (always on) — path allowlist. Default-deny; only the exact
  #     endpoints a bootstrapping vault-agent uses are proxied to OpenBao, and
  #     the version/seal recon beacon + /ui/ are 403'd. See secVhostLocations.
  #
  #   Layer 2 (openbaoJwtGate) — Zitadel-JWT pre-validation in njs. Before
  #     nginx proxies the login / KV requests to OpenBao, an njs js_content
  #     handler verifies the caller's Zitadel JWT (RS256 sig against the JWKS,
  #     plus iss/aud/exp). Without a valid Zitadel token an attacker cannot
  #     even *reach* OpenBao's login handler from the internet. Reuses the SAME
  #     machine identity the box already has — no second secret to transfer.
  #     Toggle off to fall back to Layer-1-only if njs ever misbehaves.
  #
  # The JWKS is fetched from h001 directly over the tailnet (not the public
  # sso. name), because o002 fetching its own public IP would hairpin through
  # Oracle's NAT (documented-broken; see configuration.nix headscale notes).
  openbaoJwtGate = true;

  # h001 overlay IP + the SSO Host header, for the tailnet-side JWKS fetch.
  ssoOverlayHost = fleet.hosts.h001.overlayIp; # 100.64.0.13
  zitadelDomain = constants.services.zitadel.domain or "sso.${domain}";
  jwksUri = "http://${ssoOverlayHost}/oauth/v2/keys";
  zitadelAudience = "344379162166820867"; # Zitadel project resource ID (see secrets-bao)

  openbaoDenyBody = ''
    default_type application/json;
    return 403 '{"errors":["forbidden: reach OpenBao over the tailnet (this public edge only serves machine bootstrap)"]}';
  '';

  # Layer-1 allowlist locations. When the JWT gate is ON, ONLY the login
  # endpoint runs the njs handler (it's the unauthenticated entry point). KV
  # reads carry an OpenBao *token* (not a Zitadel JWT) — vault-agent gets that
  # token FROM the gated login, so those paths are self-protecting: allowlist
  # them and let OpenBao enforce the token. Gating them would (and did) break
  # vault-agent, which sends the opaque OpenBao token there, not a JWT.
  loginLoc =
    if openbaoJwtGate
    then { extraConfig = "js_content openbao_gate.gate;\nlimit_except POST PUT { deny all; }"; }
    else { proxyPass = "http://${upstream}"; extraConfig = "limit_except POST PUT { deny all; }"; };

  secVhostLocations = {
    # (1) Zitadel-JWT login — the only write the public edge allows, and the
    # ONLY path the njs gate protects (unauthenticated entry point).
    # NB: the OpenBao Go client (vault-agent auto_auth) issues HTTP PUT for
    # logical writes; the endpoint also accepts POST. Allow both, deny the rest.
    "= /v1/auth/zitadel-jwt/login" = loginLoc;

    # (2) KV reads for machine bootstrap secrets. Authenticated by the OpenBao
    # token minted at login (which required a valid Zitadel JWT). OpenBao
    # enforces that the token's policy grants the path; the edge only narrows
    # WHICH paths are reachable (machines/* only) and to GET. No JWT gate here —
    # the caller presents an opaque OpenBao token, not a Zitadel JWT.
    "~ ^/v1/kv/(data|metadata)/machines/(high-trust|low-trust|by-host)/" = {
      proxyPass = "http://${upstream}";
      extraConfig = "limit_except GET { deny all; }";
    };

    # (3) Token self-management + self capability check. vault-agent's
    # auto_auth calls these against ITS OWN token to set up renewal after
    # login; machine-base grants sys/capabilities-self. All carry a real
    # OpenBao token (not the Zitadel JWT), so they always proxy directly.
    "~ ^/v1/auth/token/(lookup-self|renew-self)$" = {
      proxyPass = "http://${upstream}";
    };
    "= /v1/sys/capabilities-self" = {
      proxyPass = "http://${upstream}";
    };

    # Everything else (recon beacon, /ui/, sys/*, other kv paths) → 403.
    "/" = {
      extraConfig = openbaoDenyBody;
    };
  }
  # Internal upstream target used by the login njs gate after a successful verify.
  // lib.optionalAttrs openbaoJwtGate {
    "@openbao_upstream" = {
      extraConfig = ''
        internal;
        proxy_pass http://${upstream};
      '';
    };
  };

  secVhost = {
    enableACME = true;
    forceSSL = true;

    # Per-vhost rate limit + (when gated) the JWKS fetch/verify wiring.
    extraConfig = ''
      limit_req zone=openbao_bootstrap burst=20 nodelay;
      limit_req_status 429;
    '' + lib.optionalString openbaoJwtGate ''
      js_var $jwks_uri ${jwksUri};
      js_var $jwks_host ${zitadelDomain};
      js_var $jwt_issuer https://${zitadelDomain};
      js_var $jwt_audience ${zitadelAudience};
    '';

    locations = secVhostLocations;
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
    # njs module: needed for the OpenBao JWT gate (openbaoJwtGate). Compiles
    # the ngx_http_js_module into nginx. No-op at runtime if the gate is off.
    additionalModules = lib.optionals openbaoJwtGate [ pkgs.nginxModules.njs ];
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    clientMaxBodySize = "500m";
    commonHttpConfig = ''
      log_format noauth '$remote_addr - $remote_user [$time_local] '
                        '"$request" $status $body_bytes_sent '
                        '"$http_referer" "$http_user_agent"';

      # Rate-limit zone for the OpenBao bootstrap edge (sec.joshuabell.xyz).
      # ~one machine onboards at a time; this caps abusive hammering of the
      # public login/KV endpoints while leaving normal bootstrap headroom.
      limit_req_zone $binary_remote_addr zone=openbao_bootstrap:10m rate=10r/s;
    '' + lib.optionalString openbaoJwtGate ''

      # ── OpenBao Zitadel-JWT gate (njs) ──────────────────────────────
      # JWKS cache (shared across workers) + the verifier module. nginx
      # requires a resolver for ngx.fetch even though we target an IP
      # literal (h001 overlay); point it at the systemd-resolved stub
      # (always present on NixOS) rather than MagicDNS 100.100.100.100,
      # which o002 deliberately does NOT use (--accept-dns=false).
      js_shared_dict_zone zone=openbao_jwks:64k timeout=3600s;
      js_import openbao_gate from ${./openbao_jwt_gate.js};
      resolver 127.0.0.53 ipv6=off valid=30s;
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
        # ── OpenBao (sec.) — bootstrap-only public edge ──────────────────
        # Default-deny; only the two endpoints a joining machine needs are
        # reachable from the internet. See secVhost definition above.
        "sec.${domain}" = secVhost;
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
        "books.${domain}" = {
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
