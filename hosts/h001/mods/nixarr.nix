{
  ...
}:
{
  config = {
    nixarr = {
      enable = true;
      mediaDir = "/drives/wd10/nixarr/media";
      stateDir = "/var/lib/nixarr/state";

      jellyfin.enable = true; # jellyfinnnnnn!
      jellyseerr.enable = true; # request manager for media
      sabnzbd.enable = true; # Usenet downloader
      prowlarr.enable = true; # Index manager
      sonarr.enable = true; # TV
      radarr.enable = true; # Movies
      bazarr.enable = true; # subtitles for sonarr and radarr
      lidarr.enable = true; # music
    };

    services.nginx = {
      virtualHosts = {
        "jellyfin.joshuabell.xyz" = {
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:8096";
          };
        };
        "media.joshuabell.xyz" = {
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:5055";
          };
        };
        "jellyfin.h001.local.joshuabell.xyz" = {
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:8096";
          };
        };
        "media.h001.local.joshuabell.xyz" = {
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:5055";
          };
        };
      };
    };
  };
}
