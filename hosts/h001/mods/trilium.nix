{ lib, pkgs, config, ... }:
{
  config = {
    services.trilium-server = {
      enable = true;
      port = 9111;
      host = "127.0.0.1";
      dataDir = "/var/lib/trilium";
      # noAuthentication = true; # keep authentication for now
    };

    # systemd.tmpfiles.rules = [
    #   "d /var/lib/trilium 0755 trilium trilium -"
    # ];

    services.nginx = {
      virtualHosts = {
        "trilium" = {
          serverName = "h001.net.joshuabell.xyz";
          listen = [
            {
              port = 9111;
              addr = "0.0.0.0";
            }
          ];
          locations."/" = {
            proxyWebsockets = true;
            recommendedProxySettings = true;
            proxyPass = "http://127.0.0.1:9111";
          };
        };
      };
    };
  };
}
