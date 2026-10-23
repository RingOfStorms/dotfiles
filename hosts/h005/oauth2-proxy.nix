# Fleet oauth2-proxy (containers/ROUTING-PLAN.md §4, §8 step 6).
#
# One instance for every `auth = "oauth2-proxy"` route on any container
# host. Two ways in:
#   - auth_request subrequests and /oauth2/* from the host vhosts
#     (containers/cli/routes.go, oauth2Upstream) hit 100.64.0.3:4180
#     directly over the tailnet. The firewall admits 4180 only from the
#     container hosts, and only those may send X-Forwarded-* (trustedProxyIP).
#   - Browser login: sso-proxy.joshuabell.xyz (tailnet DNS → h005) is the
#     one redirect URI registered in zitadel; h005's nginx terminates TLS
#     with the wildcard from wildcard-cert.nix.
#
# Session: encrypted cookie `_oauth2_proxy` on .joshuabell.xyz, so a single
# login covers every gated name; generated vhosts strip it before the
# backend. Same zitadel client, cookie secret and env file as the legacy
# instance in containers/trilium (sec: oauth2_proxy_key_file_2026-03-15),
# so existing sessions stay valid across the move.
{
  config,
  lib,
  fleet,
  constants,
  ...
}:
let
  domain = fleet.global.domain;
  overlayIp = constants.host.overlayIp;
  port = 4180;
  signinHost = "sso-proxy.${domain}";
  # Hosts whose nginx may call auth_request (ringofstorms.containers.nginx).
  # Keep in sync when a host starts serving generated vhosts.
  clients = map (h: fleet.hosts.${h}.overlayIp) [
    "h001"
    "h003"
    "lio"
  ];
  envFile = "${fleet.global.secretsDir}/oauth2_proxy_key_file_2026-03-15";
in
{
  services.oauth2-proxy = {
    enable = true;
    httpAddress = "http://${overlayIp}:${toString port}";
    reverseProxy = true;
    trustedProxyIP = clients ++ [ "127.0.0.1" ];
    provider = "oidc";
    oidcIssuerUrl = "https://sso.${domain}";
    redirectURL = "https://${signinHost}/oauth2/callback";
    # OAUTH2_PROXY_CLIENT_ID / _CLIENT_SECRET / _COOKIE_SECRET (sec-agent.nix).
    keyFile = envFile;
    email.domains = [ "*" ];
    setXauthrequest = true;
    cookie = {
      domain = ".${domain}";
      secure = true;
      httpOnly = true;
      expire = "168h";
      refresh = "12h";
    };
    extraConfig = {
      whitelist-domain = ".${domain}";
      cookie-samesite = "lax";
      # zitadel project roles, flattened by an action into this claim.
      oidc-groups-claim = "flatRolesClaim";
      skip-provider-button = true;
    };
  };

  systemd.services.oauth2-proxy = {
    # The overlay IP comes up after tailscaled; nonlocal bind is on
    # (fleet-edge.nix), so ordering is enough.
    wants = [ "tailscaled.service" ];
    after = [
      "tailscaled.service"
      "sec-agent.service"
    ];
    # sec-agent may hydrate the env file after the first start (seen on the
    # first deploy): keep retrying instead of hitting the start limit.
    startLimitIntervalSec = 0;
    serviceConfig.RestartSec = 5;
  };

  # Only the container hosts' nginx reach the proxy directly.
  networking.firewall.extraInputRules = lib.concatMapStrings (
    ip:
    "iifname \"tailscale0\" ip saddr ${ip} tcp dport ${toString port} accept comment \"oauth2-proxy auth_request\"\n"
  ) clients;

  # Login host. Tailnet only for now (public gated routes are refused in
  # containers/lib.nix until this is published via o002).
  users.users.nginx.extraGroups = [ "acme" ];
  services.nginx.virtualHosts.${signinHost} = {
    useACMEHost = domain;
    forceSSL = true;
    listen = [
      {
        addr = overlayIp;
        port = 443;
        ssl = true;
      }
      {
        addr = overlayIp;
        port = 80;
      }
    ];
    locations."/" = {
      proxyPass = "http://${overlayIp}:${toString port}";
      extraConfig = ''
        # o002 (public edge) counts as the internet
        deny 100.64.0.5;
        deny fd7a:115c:a1e0::5;
        allow 100.64.0.0/10;
        allow fd7a:115c:a1e0::/48;
        deny all;
        proxy_set_header X-Forwarded-Uri $request_uri;
      '';
    };
  };

  assertions = [
    {
      assertion = config.security.acme.certs ? ${domain};
      message = "oauth2-proxy.nix needs the wildcard cert from wildcard-cert.nix";
    }
  ];
}
