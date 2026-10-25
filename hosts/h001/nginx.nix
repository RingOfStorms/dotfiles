{
  config,
  lib,
  constants,
  fleet,
  ...
}:
let
  c = constants.host;
  domain = fleet.global.domain;
  # The homepage-dashboard that used to live here moved to fleet-edge on h005
  # (http://h005.net.${domain}/); the old entry points are retired.
  retired = {
    locations."/".return = "500";
  };
in
{
  # Was opened by hosts/h001/containers/default.nix (old zitadel container).
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  # TLS: no ACME here. The *.joshuabell.xyz wildcard is issued on h005 and
  # pushed to /var/lib/fleet-cert (hosts/_shared_assets/utilities/wildcard-cert-receiver.nix); the
  # generated vhosts include /etc/fleet-containers/nginx-tls.conf and the
  # hand vhosts (mods/arr-nginx.nix) name it directly. ROUTING-PLAN §8 step 4.

  # nginx listens on overlay IP, needs tailscale interface up.
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

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    clientMaxBodySize = "500m";
    appendHttpConfig = ''
      proxy_headers_hash_max_size 1024;
    '';
    virtualHosts = {
      # h001.net.${domain}: /media-health/ (longer prefix, wins) is declared in
      # mods/arr-nginx.nix; everything else is retired.
      "h001.net.${domain}" = retired;
      "h001.local.${domain}" = retired;
      "${c.lanIp}" = retired;
      "${c.overlayIp}" = retired;
      "_" = {
        rejectSSL = true;
        default = true;
        locations."/" = {
          return = "444"; # 404 for not found or 444 for drop
        };
      };
    };
  };
}
