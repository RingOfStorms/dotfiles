{
  inputs,
  ...
}:
let
  declaration = "services/web-apps/trilium.nix";
  nixpkgs = inputs.open-webui-nixpkgs;
  pkgs = import nixpkgs {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgs}/nixos/modules/${declaration}" ];
  config = {
    services.trilium-server = {
      enable = true;
      package = pkgs.trilium-server;
      port = 9111;
      host = "127.0.0.1";
      dataDir = "/var/lib/trilium";
      noAuthentication = true;
      instanceName = "joshuabell";
    };

    systemd.services.trilium-server.environment = {
      TRILIUM_NO_UPLOAD_LIMIT = "true";
    };

    services.oauth2-proxy.nginx.virtualHosts."notes.joshuabell.xyz" = {
      allowed_groups = [ "notes" ];
    };
    services.nginx.virtualHosts = {
      "notes.joshuabell.xyz" = {
        locations = {
          "/" = {
            proxyWebsockets = true;
            recommendedProxySettings = true;
            proxyPass = "http://127.0.0.1:9111";
          };
        };
      };
      "trilium_overlay" = {
        serverName = "h001.net.joshuabell.xyz";
        listen = [
          {
            port = 9112;
            addr = "100.64.0.13";
          }
        ];
        locations = {
          "/" = {
            proxyWebsockets = true;
            recommendedProxySettings = true;
            proxyPass = "http://127.0.0.1:9111";
          };
        };
      };
    };
  };
}
