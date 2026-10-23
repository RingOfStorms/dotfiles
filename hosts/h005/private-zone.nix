# Private tailnet-only zone *.ts.joshuabell.xyz (containers/ROUTING-PLAN.md §2.2).
#
# Pilot shape: h005 holds the only copy of the wildcard key (it already owns
# the bunny API key) and terminates TLS for every private route, proxying
# over the tailnet to the serving host's overlay IP. Nothing is distributed
# to other hosts. Routes come from the containers inventory (zone =
# "private"); DNS for the same list is in mods/networking.nix
# (dnsmasq-tailnet), pointing at h005's overlay IP.
#
# Never public: no bunny A/CNAME records exist for this zone; only the
# _acme-challenge TXT records are written there during DNS-01.
{
  lib,
  constants,
  fleet,
  ...
}:
let
  overlayIp = constants.host.overlayIp;
  zone = "ts.${fleet.global.domain}";
  containersLib = import ../../containers/lib.nix;
  privateRoutes = containersLib.privateRoutes ../../containers;
  # oauth2-proxy cookie/identity hygiene, shared with cli/routes.go.
  inherit (containersLib) nginxSnippets;

  backend =
    r:
    let
      h = r.service.host;
    in
    if h == null || !(fleet.hosts ? ${h}) || (fleet.hosts.${h}.overlayIp or null) == null then
      throw "private route ${r.fqdn}: service ${r.service.name} has no host with an overlayIp"
    else
      "http://${fleet.hosts.${h}.overlayIp}:${toString r.port}";

  # route allow = [ hosts ]: only those hosts' overlay IPs (v4; fleet.nix
  # has no v6 overlay addresses, so v6 is denied). Unknown or off-tailnet
  # hosts fail the build rather than silently widening/narrowing the ACL.
  # Empty allow: the whole tailnet, as before.
  sourceAcl =
    r:
    if r.allow == [ ] then
      ''
        allow 100.64.0.0/10;
        allow fd7a:115c:a1e0::/48;''
    else
      lib.concatMapStringsSep "\n" (
        a:
        let
          ip = (fleet.hosts.${a} or { }).overlayIp or null;
        in
        if ip == null then
          throw "private route ${r.fqdn}: allow host ${a} has no overlayIp in fleet.nix"
        else
          "allow ${ip}; # ${a}"
      ) r.allow;
  vhost = r: {
    name = r.fqdn;
    value = {
      useACMEHost = zone;
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
      extraConfig = ''
        client_max_body_size ${r.maxBody};
        ${nginxSnippets.cookieStrip}
      '';
      locations."/" = {
        proxyPass = backend r;
        proxyWebsockets = r.websockets;
        extraConfig = ''
          # o002 (public edge) counts as the internet
          deny 100.64.0.5;
          deny fd7a:115c:a1e0::5;
          ${sourceAcl r}
          deny all;
          proxy_buffering ${if r.buffering then "on" else "off"};
          proxy_read_timeout ${r.timeouts};
          proxy_send_timeout ${r.timeouts};
          ${nginxSnippets.identityClear}
        '';
      };
    };
  };
in
{
  security.acme = {
    acceptTerms = true;
    defaults.email = fleet.global.acmeEmail;
    certs.${zone} = {
      domain = "*.${zone}";
      # credentialFiles.BUNNY_API_KEY_FILE injected via sec-agent configChanges
      # (hosts/h005/sec-agent.nix).
      dnsProvider = "bunny";
      group = "nginx";
    };
  };

  services.nginx = {
    recommendedTlsSettings = true;
    virtualHosts = builtins.listToAttrs (map vhost privateRoutes);
  };

  # Explicit, so this keeps working once tailscale0 is no longer trusted
  # (ROUTING-PLAN §5.1).
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];

  # Assert the pilot didn't silently produce nothing.
  warnings = lib.optional (
    privateRoutes == [ ]
  ) "private-zone: no zone = \"private\" routes in the containers inventory";
}
