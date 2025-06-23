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
      readarr.enable = true; # books
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
        "jellyfin.h001.n.joshuabell.xyz" = {
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:8096";
          };
        };
        "media.h001.n.joshuabell.xyz" = {
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:5055";
          };
        };
        "sabnzbd.h001.n.joshuabell.xyz" = {
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:6336";
          };
        };
        "prowlarr.h001.n.joshuabell.xyz" = {
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:9696";
          };
        };
        "radarr.h001.n.joshuabell.xyz" = {
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:7878";
          };
        };
        "sonarr.h001.n.joshuabell.xyz" = {
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:8989";
          };
        };
        "lidarr.h001.n.joshuabell.xyz" = {
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:8686";
          };
        };
        "readarr.h001.n.joshuabell.xyz" = {
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:8787";
          };
        };
        "bazarr.h001.n.joshuabell.xyz" = {
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:6767";
          };
        };
      };
    };
  };
}
