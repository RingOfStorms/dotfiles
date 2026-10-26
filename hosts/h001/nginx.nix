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
  # 80/443, the nginx ordering after tailscale, the recommended settings, the
  # 444/reject-handshake catch-all and the cert come from the containers host
  # module (generated vhosts in /var/lib/fleet-containers/nginx). TLS: the
  # *.joshuabell.xyz wildcard issued on h005 and pushed to /var/lib/fleet-cert
  # (hosts/_shared_assets/utilities/wildcard-cert-receiver.nix, imported by
  # the module); the hand vhosts (mods/arr-nginx.nix) name it directly.
  services.nginx = {
    clientMaxBodySize = "500m";
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
