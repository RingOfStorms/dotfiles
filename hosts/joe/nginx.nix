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
  # nginx waits for tailscale to be up (listens on overlay IP)
  systemd.services.nginx = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "tailscaled.service" ];
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
