{
  lib,
  ...
}:
{
  config = {
    services.pinchflat = {
      enable = true;
      port = 8945;
      selfhosted = true;
      mediaDir = "/drives/wd10/pinchflat/media";
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

    systemd.tmpfiles.rules = [
      "d '/drives/wd10/pinchflat/media' 0775 pinchflat pinchflat - -"
    ];

    # services.nginx = {
    #   virtualHosts = {
    #     "yt.joshuabell.xyz" = {
    #       locations."/" = {
    #         proxyWebsockets = true;
    #         proxyPass = "http://localhost:8945";
    #       };
    #     };
    #   };
    # };
  };
}
