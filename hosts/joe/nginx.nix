{ constants, fleet, ... }:
let
  c = constants.host;
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

  # joe used to serve a homepage-dashboard here; the start page is now
  # fleet-edge on h005. Redirect so old bookmarks keep working.
  services.nginx = {
    enable = true;
    virtualHosts = {
      "localhost" = {
        listen = [
          { addr = "127.0.0.1"; port = 80; }
          { addr = c.overlayIp; port = 80; }
        ];
        locations."/".return = "302 http://h005.net.${fleet.global.domain}/";
      };
    };
  };
}
