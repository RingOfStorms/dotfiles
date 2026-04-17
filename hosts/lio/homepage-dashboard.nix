# Local services dashboard for lio.
# Bound to localhost only via nginx (see ./nginx.nix).
{ constants, ... }:
let
  s = constants.services;
  section = "a. Terminals";
in
{
  services.homepage-dashboard = {
    enable = true;
    openFirewall = false;
    allowedHosts = "*";
    settings = {
      title = "lio — Local Services";
      favicon = "https://twenty-icons.com/search.nixos.org";
      color = "neutral";
      theme = "dark";
      iconStyle = "theme";
      headerStyle = "clean";
      hideVersion = true;
      disableUpdateCheck = true;
      language = "en";
      layout = {
        "${section}" = {
          style = "row";
          columns = 2;
        };
      };
    };
    services = [
      {
        "${section}" = [
          {
            "ttyd (LAN)" = {
              description = "Web terminal on 10.12.14.118:${toString s.ttyd.port}";
              href = "http://10.12.14.118:${toString s.ttyd.port}";
              icon = "mdi-console";
            };
          }
          {
            "ttyd (Tailnet)" = {
              description = "Web terminal on 100.64.0.1:${toString s.ttyd.port}";
              href = "http://100.64.0.1:${toString s.ttyd.port}";
              icon = "mdi-console-network";
            };
          }
        ];
      }
    ];
  };
}
