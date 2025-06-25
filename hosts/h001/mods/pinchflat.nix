{
  ...
}:
{
  config = {
    services.pinchflat = {
      enable = true;
      port = 8945;
      mediaDir = "/drives/wd10/nixarr/media/library/youtube";
    };

    # Adds the pinchflat user to the nixarr media group so we can write to the same media folder
    systemd.services.pinchflat.serviceConfig.SupplementaryGroups = [ "media" ];
    systemd.tmpfiles.rules = [
      "d '/drives/wd10/nixarr/media/library/youtube' 0775 root media - -"
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
