let
  section1 = "a. Public Apps";
  section2 = "b. Media*rrs";
  section3 = "c. Network";
in
{
  services.homepage-dashboard = {
    enable = true;
    openFirewall = false;
    allowedHosts = "*";
    settings = {
      title = "Josh's Homelab";
      background = "https://w.wallhaven.cc/full/k9/wallhaven-k912lq.png";
      favicon = "https://twenty-icons.com/search.nixos.org";
      cardBlur = "xs";
      color = "neutral";
      theme = "dark";
      iconStyle = "theme";
      headerStyle = "clean";
      hideVersion = true;
      disableUpdateCheck = true;
      language = "en";
      layout = {
        "${section1}" = {
          style = "row";
          columns = 4;
        };
        "${section2}" = {
          style = "row";
          columns = 3;
        };
        "${section3}" = {
          style = "row";
          columns = 2;
        };
      };
    };
    services = [
      {
        "${section1}" = [
          {
            "Git" = {
              description = "Forgejo";
              href = "https://git.joshuabell.xyz";
              icon = "forgejo";
              # widgets = [
              #   {
              #     type = "gitea";
              #     url = "https://git.joshuabell.xyz";
              #     key = "TODO";
              #     hideErrors = true;
              #   }
              # ];
            };
          }
          {
            "Gist" = {
              description = "Opengist";
              href = "https://gist.joshuabell.xyz";
              icon = "opengist";
            };
          }
          {
            "Open WebUI" = {
              description = "LLM Chats";
              href = "https://chat.joshuabell.xyz";
              icon = "openai";
            };
          }
        ];
      }
      {
        "${section2}" = [
          {
            "Jellyfin" = {
              description = "Media Streaming";
              href = "https://jellyfin.joshuabell.xyz";
              icon = "jellyfin";
            };
          }
          {
            "Jellyseerr" = {
              description = "Media Requests";
              href = "https://media.joshuabell.xyz";
              icon = "jellyseerr";
            };
          }
          {
            "Pinchflat" = {
              description = "YouTube Automation";
              href = "http://h001.net.joshuabell.xyz:8945";
              icon = "pinchflat";
            };
          }
          {
            "Radarr" = {
              description = "Movie Automation";
              href = "http://h001.net.joshuabell.xyz:7878";
              icon = "radarr";
            };
          }
          {
            "Sonarr" = {
              description = "Show Automation";
              href = "http://h001.net.joshuabell.xyz:8989";
              icon = "sonarr";
            };
          }
          {
            "Bazarr" = {
              description = "Subtitle Automation";
              href = "http://h001.net.joshuabell.xyz:6767";
              icon = "bazarr";
            };
          }
          {
            "Prowlarr" = {
              description = "Indexer Manager";
              href = "http://h001.net.joshuabell.xyz:9696";
              icon = "prowlarr";
            };
          }
          {
            "SABnzbd" = {
              description = "Usenet Downloader";
              href = "http://h001.net.joshuabell.xyz:6336";
              icon = "sabnzbd";
            };
          }
          {
            "Transmission" = {
              description = "Torrent Downloader";
              href = "http://h001.net.joshuabell.xyz:9091";
              icon = "transmission";
            };
          }
        ];
      }
      {
        "${section3}" = [
          {
            "AdGuard Home" = {
              description = "Network-wide Ad-blocker";
              href = "http://h003.net.joshuabell.xyz:3000";
              icon = "adguard-home";
              widgets = [
                {
                  type = "adguard";
                  url = "http://h003.net.joshuabell.xyz:3000/";
                  username = "opidsjhpoidjsf";
                  password = "TODO";
                  hideErrors = true;
                }
              ];
            };
          }
          {
            "Beszel" = {
              description = "Server Metrics";
              href = "http://h001.net.joshuabell.xyz:8090";
              icon = "beszel";
            };
          }
        ];
      }
    ];
  };
}
