{
  lib,
  inputs,
  ...
}:
let
  declaration = "services/misc/pinchflat.nix";
  nixpkgs = inputs.pinchflat-nixpkgs;
  pkgs = import nixpkgs {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgs}/nixos/modules/${declaration}" ];
  config = {
    services.pinchflat = {
      package = pkgs.pinchflat;
      enable = true;
      port = 8945;
      selfhosted = true;
      mediaDir = "/drives/wd10/pinchflat/media";
      extraConfig = {
        YT_DLP_WORKER_CONCURRENCY = 1;
      };
    };

    users.users.pinchflat.isSystemUser = true;
    users.users.pinchflat.group = "pinchflat";
    users.groups.pinchflat = { };
    systemd.services.pinchflat.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "pinchflat";
      Group = "pinchflat";
    };

    # Use Nixarr vpn
    systemd.services.pinchflat.vpnconfinement = {
      enable = true;
      vpnnamespace = "wg";
    };
    vpnNamespaces.wg.portMappings = [
      {
        from = 8945;
        to = 8945;
      }
    ];

    systemd.tmpfiles.rules = [
      "d '/drives/wd10/pinchflat/media' 0775 pinchflat pinchflat - -"
    ];

    services.nginx = {
      virtualHosts = {
        "pinchflat" = {
          serverName = "h001.net.joshuabell.xyz";
          listen = [
            {
              port = 8945;
              addr = "0.0.0.0";
            }
          ];
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://192.168.15.1:8945";
          };
        };
      };
    };
  };
}
