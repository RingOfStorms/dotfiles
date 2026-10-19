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
  privateRoutes = (import ../../containers/lib.nix).privateRoutes ../../containers;

  backend =
    r:
    let
      h = r.service.host;
    in
    if h == null || !(fleet.hosts ? ${h}) || (fleet.hosts.${h}.overlayIp or null) == null then
      throw "private route ${r.fqdn}: service ${r.service.name} has no host with an overlayIp"
    else
      "http://${fleet.hosts.${h}.overlayIp}:${toString r.port}";

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
      '';
      locations."/" = {
        proxyPass = backend r;
        proxyWebsockets = r.websockets;
        extraConfig = ''
          allow 100.64.0.0/10;
          allow fd7a:115c:a1e0::/48;
          deny all;
          proxy_buffering ${if r.buffering then "on" else "off"};
          proxy_read_timeout ${r.timeouts};
          proxy_send_timeout ${r.timeouts};
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
  warnings = lib.optional (privateRoutes == [ ]) "private-zone: no zone = \"private\" routes in the containers inventory";
}
