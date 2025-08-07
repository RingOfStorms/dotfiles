{
  config,
  ...
}:
{
  config = {
    nixarr = {
      enable = true;
      mediaDir = "/drives/wd10/nixarr/media";
      stateDir = "/var/lib/nixarr/state";

      vpn = {
        enable = true;
        wgConf = config.age.secrets.us_chi_wg.path;
      };

      jellyfin.enable = true; # jellyfinnnnnn!
      jellyfin.vpn.enable = true;
      jellyseerr.enable = true; # request manager for media
      jellyseerr.vpn.enable = true;
      sabnzbd.enable = true; # Usenet downloader
      transmission = {
        enable = true; # Torrent downloader
        vpn.enable = true;
        peerPort = 51820;
        extraAllowedIps = [
          "100.64.0.0/10"
        ];
        extraSettings = {
          rpc-bind-address = "0.0.0.0";
          rpc-authentication-required = false;
          rpc-username = "transmission";
          rpc-password = "transmission";
          rpc-host-whitelist-enabled = false;
          rpc-whitelist-enabled = false;
          rpc-whitelist = "127.0.0.1,::1,192.168.1.71,100.64.0.0/10";
        };
      };
      prowlarr.enable = true; # Index manager
      sonarr.enable = true; # TV
      radarr.enable = true; # Movies
      bazarr.enable = true; # subtitles for sonarr and radarr
      lidarr.enable = false; # music
      # recyclarr.enable = true; # not sure how to use this yet
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
        "10.12.14.10" = {
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:8096";
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
