{
  lib,
  inputs,
  config,
  pkgs,
  ...
}:
let
  declaration = "services/misc/pinchflat.nix";
  nixpkgsPinchflat = inputs.pinchflat-nixpkgs;
  pkgsPinchflat = import nixpkgsPinchflat {
    inherit (pkgs) system;
    config.allowUnfree = true;
  };

  gid = 186;
  uid = 186;
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgsPinchflat}/nixos/modules/${declaration}" ];
  config = lib.mkIf config.nixarr.enable {
    services.pinchflat = {
      package = pkgsPinchflat.pinchflat;
      enable = true;
      port = 8945;
      selfhosted = true;
      mediaDir = "/nfs/h002/pinchflat/media";
      # mediaDir = "/drives/wd10/pinchflat/media";
      extraConfig = {
        YT_DLP_WORKER_CONCURRENCY = 1;
      };
    };

    users = {
      groups.pinchflat.gid = gid;
      users.pinchflat = {
        isSystemUser = true;
        group = "pinchflat";
        uid = uid;
      };
    };

    systemd.tmpfiles.rules = [
      "d '${config.services.pinchflat.mediaDir}' 0775 pinchflat pinchflat - -"
    ];

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
