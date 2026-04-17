# nginx vhost on lio: serves the homepage dashboard at http://localhost/.
#
# Note: the catch-all default vhost (returns 404) and the firewall opening
# of ports 80/443 live in ./containers.nix. This file only adds the
# "localhost" virtual host; remote requests still hit the default 404.
{ constants, ... }:
let
  homepagePort = constants.services.homepage.port;
  homepage = {
    proxyWebsockets = true;
    proxyPass = "http://localhost:${toString homepagePort}";
  };
in
{
  services.nginx.virtualHosts."localhost" = {
    serverName = "localhost";
    listen = [
      { addr = "127.0.0.1"; port = 80; }
      { addr = "[::1]";     port = 80; }
    ];
    locations."/" = homepage;
  };
}
