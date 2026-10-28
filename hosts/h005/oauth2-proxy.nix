# Fleet oauth2-proxy (containers/ROUTING-PLAN.md §4, §8 step 6).
#
# One instance for every `auth = "oauth2-proxy"` route on any container
# host. Three ways in:
#   - auth_request subrequests and /oauth2/* from the host vhosts
#     (containers/cli/routes.go, oauth2Upstream) hit 100.64.0.3:4180
#     directly over the tailnet. The firewall admits 4180 only from the
#     container hosts, and only those may send X-Forwarded-* (trustedProxyIP).
#   - Browser login over the tailnet: sso-proxy.joshuabell.xyz resolves to
#     h005 for tailnet/LAN clients (tailnet DNS); h005's nginx terminates
#     TLS with the wildcard from wildcard-cert.nix.
#   - Browser login from the internet: sso-proxy.joshuabell.xyz resolves
#     publicly to o002 (CNAME, dns-records.nix publicSpec), whose nginx
#     proxies only `/oauth2/` to h005's edge listener below
#     (<overlayIp>:edgePort, admitted from o002's overlay IP only). o002
#     never satisfies a tailnet ACL: it is excluded from the broad
#     tailnet 80/443 accept in firewall.nix and gets its own narrow rule.
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
  inputs,
  ...
}:
let
  domain = fleet.global.domain;
  overlayIp = constants.host.overlayIp;
  port = 4180;
  signinHost = "sso-proxy.${domain}";
  # Hosts whose nginx may call auth_request (ringofstorms.containers.nginx):
  # generated from the inventory (containers/flake.nix containerHosts),
  # the same list the CLI probes. No hand-kept duplicate list to drift.
  clients = map (h: fleet.hosts.${h}.overlayIp) inputs.containers.inventory.containerHosts;
  # Public edge (o002): the only caller allowed to reach the edge listener
  # below, and the only one whose X-Forwarded-* that listener trusts.
  # Never admitted to the tailnet vhost (ROUTING-PLAN §8 step 2: o002 is
  # excluded from h005's broad tailnet 80/443 accept in firewall.nix).
  o002Ip = fleet.hosts.o002.overlayIp;
  o002Ip6 = "fd7a:115c:a1e0::5";
  edgePort = 8443;
  envFile = "${fleet.global.secretsDir}/oauth2_proxy_key_file_2026-03-15";
in
{
  services.oauth2-proxy = {
    enable = true;
    httpAddress = "http://${overlayIp}:${toString port}";
    reverseProxy = true;
    # h005's own nginx connects from its overlay IP (edge listener below);
    # h005 isn't in `clients` (not a container host), so no dedupe needed,
    # but lib.unique keeps this safe if that ever changes.
    trustedProxyIP = lib.unique (
      clients
      ++ [
        overlayIp
        "127.0.0.1"
      ]
    );
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
  networking.firewall.extraInputRules =
    lib.concatMapStrings (
      ip:
      "iifname \"tailscale0\" ip saddr ${ip} tcp dport ${toString port} accept comment \"oauth2-proxy auth_request\"\n"
    ) clients
    # Edge listener below (public sso-proxy): admitted only from o002, v4+v6
    # (ROUTING-PLAN §8 step 6). o002 never reaches 4180 directly or any other
    # tailnet port on h005 (firewall.nix excludes it from the broad accept).
    + "iifname \"tailscale0\" ip saddr ${o002Ip} tcp dport ${toString edgePort} accept comment \"oauth2-proxy edge listener, o002 only\"\n"
    + "iifname \"tailscale0\" ip6 saddr ${o002Ip6} tcp dport ${toString edgePort} accept comment \"oauth2-proxy edge listener, o002 only (v6)\"\n";

  users.users.nginx.extraGroups = [ "acme" ];
  # Tailnet/LAN sign-in: full UI (start, callback, sign_out), proxied
  # directly to oauth2-proxy. Internet clients can't resolve this name
  # (split DNS); o002 is explicitly excluded (it counts as the internet).
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
      # h005's nginx has recommendedProxySettings = true globally
      # (fleet-edge.nix), whose X-Forwarded-For is
      # $proxy_add_x_forwarded_for (appends to any client-supplied
      # value). oauth2-proxy trusts h005's overlay IP (trustedProxyIP),
      # so a tailnet client could otherwise spoof its own client IP.
      # Disable it here and set every header by hand.
      recommendedProxySettings = false;
      extraConfig = ''
        # o002 (public edge) counts as the internet
        deny ${o002Ip};
        deny ${o002Ip6};
        allow 100.64.0.0/10;
        allow fd7a:115c:a1e0::/48;
        deny all;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Uri $request_uri;
      '';
    };
  };

  # Public edge listener (ROUTING-PLAN §8 step 6): plain http, admitted by
  # the firewall from o002 only (extraInputRules above), serving only
  # /oauth2/ so a public `rd` and the zitadel callback work. o002's
  # X-Forwarded-* is trusted here ONLY (real_ip from o002's overlay
  # addresses alone): every other listener on h005 ignores it. o002's
  # nginx proxies `sso-proxy.${domain}` to exactly this
  # `<overlayIp>:${edgePort}`, the edge hop pattern from
  # containers/lib.nix edgeVirtualHosts.
  services.nginx.virtualHosts."${signinHost}-edge" = {
    serverName = signinHost;
    listen = [
      {
        addr = overlayIp;
        port = edgePort;
      }
    ];
    extraConfig = ''
      set_real_ip_from ${o002Ip};
      set_real_ip_from ${o002Ip6};
      real_ip_header X-Forwarded-For;
      real_ip_recursive off;
    '';
    locations."/oauth2/" = {
      proxyPass = "http://${overlayIp}:${toString port}/oauth2/";
      # h005's nginx has recommendedProxySettings = true globally
      # (fleet-edge.nix), and the module `include`s that config AFTER
      # extraConfig, so proxy_set_header overrides here would otherwise be
      # clobbered by it. Disable it for this location and set every header
      # by hand instead.
      recommendedProxySettings = false;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Uri $request_uri;
        # The client's real scheme is https (o002 terminates TLS; this
        # listener itself is plain http). X-Forwarded-Host: the sign-in
        # name, not h005's. X-Forwarded-For: real_ip above already
        # resolved $remote_addr to the real client from o002's (trusted
        # here only) X-Forwarded-For; set it explicitly rather than
        # appending with $proxy_add_x_forwarded_for, which would carry
        # o002's incoming (spoofable) X-Forwarded-For value too.
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
      '';
    };
    locations."/" = {
      return = "444";
    };
  };

  assertions = [
    {
      assertion = config.security.acme.certs ? ${domain};
      message = "oauth2-proxy.nix needs the wildcard cert from wildcard-cert.nix";
    }
  ];
}
