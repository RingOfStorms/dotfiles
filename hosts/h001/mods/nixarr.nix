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
        "100.64.0.13" = {
          locations = {
            "/jellyfin" = {
              proxyPass = "http://localhost:8096";
              extraConfig = ''
                rewrite ^/jellyfin/(.*) /$1 break;
              '';
            };
            "/jellyseerr" = {
              proxyPass = "http://localhost:5055";
              extraConfig = ''
                rewrite ^/jellyseerr/(.*) /$1 break;
              '';
            };
            "/sabnzbd" = {
              proxyPass = "http://localhost:6336";
              extraConfig = ''
                rewrite ^/sabnzbd/(.*) /$1 break;
              '';
            };
            "/prowlarr" = {
              proxyPass = "http://localhost:9696";
              extraConfig = ''
                rewrite ^/prowlarr/(.*) /$1 break;
              '';
            };
            "/radarr" = {
              proxyPass = "http://localhost:7878";
              extraConfig = ''
                rewrite ^/radarr/(.*) /$1 break;
              '';
            };
            "/sonarr" = {
              proxyPass = "http://localhost:8989";
              extraConfig = ''
                rewrite ^/sonarr/(.*) /$1 break;
              '';
            };
            "/lidarr" = {
              proxyPass = "http://localhost:8686";
              extraConfig = ''
                rewrite ^/lidarr/(.*) /$1 break;
              '';
            };
            "/readarr" = {
              proxyPass = "http://localhost:8787";
              extraConfig = ''
                rewrite ^/readarr/(.*) /$1 break;
              '';
            };
            "/bazarr" = {
              proxyPass = "http://localhost:6767";
              extraConfig = ''
                rewrite ^/bazarr/(.*) /$1 break;
              '';
            };
          };
        };
      };
    };
  };
}
