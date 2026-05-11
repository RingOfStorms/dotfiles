{ constants, ... }:
let
  c = constants.host;
  homepagePort = constants.services.homepage.port;
  homepage = {
    proxyWebsockets = true;
    proxyPass = "http://localhost:${toString homepagePort}";
  };
in
{
  # nginx waits for tailscale to be up (listens on overlay IP).
  # tailscaled-autoconnect.service (Type=notify) only finishes once `tailscale up`
  # has returned and tailscale0 has its address; tailscaled.service alone is just
  # the daemon being started and races nginx's bind. IPFreeBind=true also lets
  # nginx bind to addresses not yet on any interface as belt-and-suspenders.
  systemd.services.nginx = {
    wants = [ "network-online.target" "tailscaled-autoconnect.service" ];
    after = [ "network-online.target" "tailscaled-autoconnect.service" ];
    serviceConfig.IPFreeBind = true;
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts = {
      "localhost" = {
        listen = [
          { addr = "127.0.0.1"; port = 80; }
          { addr = c.overlayIp; port = 80; }
        ];
        locations."/" = homepage;
      };
    };
  };
}
