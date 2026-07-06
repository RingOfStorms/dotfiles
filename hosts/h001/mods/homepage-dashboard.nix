{ constants, ... }:
let
  section1 = "a. Public Apps";
  section2 = "b. Media*rrs";
  section3 = "c. Photos & Docs";
  section4 = "d. Comms";
  section5 = "e. Identity & Security";
  section6 = "f. Network";
  s = constants.services;
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
          columns = 4;
        };
        "${section4}" = {
          style = "row";
          columns = 2;
        };
        "${section5}" = {
          style = "row";
          columns = 4;
        };
        "${section6}" = {
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
              href = "https://${s.forgejo.domain}";
              icon = "forgejo";
            };
          }
          {
            "Gist" = {
              description = "Opengist";
              href = "https://${s.opengist.domain}";
              icon = "opengist";
            };
          }
          {
            "Open WebUI" = {
              description = "LLM Chats";
              href = "https://${s.openWebui.domain}";
              icon = "openai";
            };
          }
          {
            "n8n" = {
              description = "Workflow Automation";
              href = "https://${s.n8n.domain}";
              icon = "n8n";
            };
          }
          {
            "Puzzles" = {
              description = "Puzzles";
              href = "https://${s.puzzles.domain}";
              icon = "mdi-puzzle";
            };
          }
        ];
      }
      {
        "${section2}" = [
          {
            "Jellyfin" = {
              description = "Media Streaming";
              href = "https://${s.nixarr.jellyfinDomain}";
              icon = "jellyfin";
            };
          }
          {
            "Jellyseerr" = {
              description = "Media Requests";
              href = "https://${s.nixarr.jellyseerrDomain}";
              icon = "jellyseerr";
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
            "Photos" = {
              description = "Immich";
              href = "https://${s.immich.domain}";
              icon = "immich";
            };
          }
          {
            "Docs" = {
              description = "Paperless-ngx";
              href = "https://${s.paperless.domain}";
              icon = "paperless-ngx";
            };
          }
          {
            "Notes" = {
              description = "Trilium";
              href = "https://${s.trilium.domain}";
              icon = "trilium-notes";
            };
          }
          {
            "Location" = {
              description = "Dawarich";
              href = "https://${s.dawarich.domain}";
              icon = "mdi-map-marker";
            };
          }
        ];
      }
      {
        "${section4}" = [
          {
            "Matrix" = {
              description = "Synapse Homeserver";
              href = "https://${s.matrix.serverName}";
              icon = "matrix";
            };
          }
          {
            "Element" = {
              description = "Matrix Client";
              href = "https://${s.matrix.elementDomain}";
              icon = "element";
            };
          }
        ];
      }
      {
        "${section5}" = [
          {
            "SSO" = {
              description = "Zitadel";
              href = "https://${s.zitadel.domain}";
              icon = "zitadel";
            };
          }
          {
            "Vault" = {
              description = "OpenBao";
              href = "https://${s.openbao.domain}";
              icon = "vault";
            };
          }
          {
            "Etebase" = {
              description = "Encrypted Sync";
              href = "https://${s.etebase.domain}";
              icon = "mdi-sync";
            };
          }
          {
            "PIM" = {
              description = "Etebase Web";
              href = "https://${s.etebase.webDomain}";
              icon = "mdi-contacts";
            };
          }
        ];
      }
      {
        "${section6}" = [
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
              href = "http://h001.net.joshuabell.xyz:${toString s.beszelHub.port}";
              icon = "beszel";
            };
          }
        ];
      }
    ];
  };
}
