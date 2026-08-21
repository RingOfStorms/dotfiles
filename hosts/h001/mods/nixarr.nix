{
  config,
  lib,
  constants,
  fleet,
  ...
}:
let
  c = constants.services.nixarr;
in
{
  config = {
    nixarr = {
      enable = true;
      # mediaDir = "/drives/wd10/nixarr/media";
      mediaDir = c.mediaDir;
      stateDir = c.stateDir;

      vpn = {
        enable = true;
        # wgConf injected via sec-agent configChanges
      };

      jellyfin.enable = true; # jellyfinnnnnn!
      # Jellyfin is deliberately NOT in the VPN namespace.
      #
      # With vpn.enable = true all Jellyfin egress leaves via the commercial
      # wg endpoint, and TMDB/fanart.tv rate-limit or block those exit IPs.
      # Metadata lookups then fail and Jellyfin falls back to an
      # ffmpeg-extracted video frame as the Primary image, which is why the
      # library showed generated thumbnails instead of real posters.
      #
      # Jellyfin only ever serves LAN/tailnet clients through the nginx vhost
      # below, so it does not need VPN egress. openFirewall stays false: port
      # 8096 is bound locally and only reachable via nginx.
      #
      # Side effect of flipping this off: nixarr stops synthesizing its own
      # "127.0.0.1:8096" nginx vhost (which proxied to the netns address) and
      # Jellyfin binds 8096 directly, so the vhost below keeps working as-is.
      jellyfin.vpn.enable = false;
      seerr.enable = true; # request manager for media (was jellyseerr; renamed in nixarr)
      # seerr.vpn.enable = true; # NOTE makes it not able to communicate to *arr apps
      sabnzbd = {
        enable = true; # Usenet downloader
        # Accessed directly at http://h001.net.joshuabell.xyz:6336 (no nginx
        # proxy). openFirewall binds the GUI to 0.0.0.0 and opens port 6336;
        # whitelistHostnames must include the FQDN or sabnzbd refuses the
        # connection ("Refused connection with hostname ...").
        openFirewall = true;
        whitelistHostnames = [
          "h001"
          "h001.net.joshuabell.xyz"
        ];
        # You reach the GUI over the tailnet (h001.net.joshuabell.xyz =>
        # 100.64.0.13). sabnzbd treats the CGNAT/tailnet range 100.64.0.0/10
        # as "external internet" and blocks it ("External internet access
        # denied") unless it's listed as a local range. Add tailnet + LAN.
        whitelistRanges = [
          "100.64.0.0/10"
          "10.12.14.0/24"
        ];
      };
      transmission = {
        enable = true; # Torrent downloader
        vpn.enable = true;
        peerPort = c.transmissionPeerPort;
        extraAllowedIps = [
          "100.64.0.0/10"
        ];
        extraSettings = {
          rpc-bind-address = "0.0.0.0";
          rpc-authentication-required = false;
          rpc-host-whitelist-enabled = false;
          rpc-whitelist-enabled = false;
          rpc-whitelist = "127.0.0.1,::1,192.168.1.71,100.64.0.0/10";
        };
      };
      prowlarr = {
        enable = true; # Index manager
        settings-sync = {
          # Nixarr keeps the existing names/implementations and updates only
          # these explicit fields; credentials remain host-managed files.
          enable-nixarr-apps = true;
          sonarr.config.fields = {
            syncCategories = [
              5000 5010 5020 5030 5040 5045 5050 5090
            ];
            animeSyncCategories = [ 5070 ];
            syncAnimeStandardFormatSearch = true;
            syncRejectBlocklistedTorrentHashesWhileGrabbing = false;
          };
          radarr.config.fields = {
            syncCategories = [
              2000 2010 2020 2030 2040 2045 2050 2060 2070 2080 2090
            ];
            syncRejectBlocklistedTorrentHashesWhileGrabbing = false;
          };
          indexers = [
            {
              name = "AnimeTosho";
              sort_name = "animetosho";
              priority = 25;
              fields = {
                baseUrl = "https://feed.animetosho.org";
                apiPath = "/api";
              };
            }
            {
              name = "LimeTorrents";
              sort_name = "limetorrents";
              priority = 25;
              fields = {
                downloadlink = 1;
                downloadlink2 = 0;
                sort = 0;
              };
            }
            {
              name = "NZBgeek";
              sort_name = "nzbgeek";
              priority = 25;
              fields = {
                baseUrl = "https://api.nzbgeek.info";
                apiPath = "/api";
                apiKey.secret = "${fleet.global.secretsDir}/nzbgeek_api_key_2026-07-15";
              };
            }
            {
              name = "The Pirate Bay";
              sort_name = "pirate bay";
              priority = 25;
            }
          ];
        };
      };
      sonarr = {
        enable = true; # TV
        settings-sync = {
          transmission.enable = true;
          downloadClients = [
            {
              name = "SABnzbd";
              implementation = "Sabnzbd";
              enable = true;
              fields = {
                host = "localhost";
                port = 6336;
                useSsl = false;
                apiKey.secret = "${fleet.global.secretsDir}/sabnzbd_api_key_2026-07-15";
                tvCategory = "tv";
                recentTvPriority = -100;
                olderTvPriority = -100;
              };
            }
          ];
        };
      };
      radarr = {
        enable = true; # Movies
        settings-sync = {
          transmission.enable = true;
          downloadClients = [
            {
              name = "SABnzbd";
              implementation = "Sabnzbd";
              enable = true;
              fields = {
                host = "localhost";
                port = 6336;
                useSsl = false;
                apiKey.secret = "${fleet.global.secretsDir}/sabnzbd_api_key_2026-07-15";
                movieCategory = "movies";
                recentMoviePriority = -100;
                olderMoviePriority = -100;
              };
            }
          ];
        };
      };
       bazarr = {
        enable = true; # subtitles for sonarr and radarr
        settings-sync = {
          sonarr.enable = true;
          radarr.enable = true;
        };
      };
      # Direct tailnet/LAN access, matching SABnzbd and the existing *arr UIs.
      # Configure Shelfmark's acquisition sources/destinations and both apps'
      # accounts/libraries in their own UIs; nixarr manages service state/paths.
      shelfmark = {
        enable = true;
        port = c.shelfmarkPort;
        host = "0.0.0.0";
        openFirewall = true;
      };
      audiobookshelf = {
        enable = true;
        port = c.audiobookshelfPort;
        host = "0.0.0.0";
        openFirewall = true;
      };
      lidarr.enable = false; # preserved in the h001 migration backup; out of scope
      recyclarr = {
        enable = true;
        # Profiles are declarative. Existing movies/series are deliberately not
        # reassigned until their current roots, tags, and profiles are inventoried.
        configuration = {
          sonarr.sonarr = {
            base_url = "http://127.0.0.1:8989";
            api_key = "!env_var SONARR_API_KEY";
            quality_definition.type = "series";
            media_management.propers_and_repacks = "do_not_prefer";
            quality_profiles = [
              {
                trash_id = "72dae194fc92bf828f32cde7744e51a1"; # WEB-1080p
                name = "HD";
                reset_unmatched_scores.enabled = true;
              }
              {
                trash_id = "d1498e7d189fbe6c7110ceaabb7473e6"; # WEB-2160p
                name = "UHD";
                reset_unmatched_scores.enabled = true;
              }
              {
                trash_id = "20e0fc959f1f1704bed501f23bdae76f"; # [Anime] Remux-1080p
                name = "Anime";
                reset_unmatched_scores.enabled = true;
              }
            ];
            custom_format_groups.add = [
              {
                trash_id = "59c3af66780d08332fdc64e68297098f"; # [Unwanted] Unwanted Formats
                select = [
                  "32b367365729d530ca1c124a0b180c64" # Bad Dual Groups
                  "85c61753df5da1fb2aab6f2a47426b09" # BR-DISK
                  "9c11cd3f07101cdba90a2d81cf0e56b4" # LQ
                  "e2315f990da2e2cbfc9fa5b7a6fcfe48" # LQ (Release Title)
                  "23297a736ca77c0fc8e70f8edd7ee56c" # Upscaled
                ];
              }
            ];
            custom_formats = [
              {
                trash_ids = [ "418f50b10f1907201b6cfdf881f467b7" ]; # Anime Dual Audio
                assign_scores_to = [{ name = "Anime"; score = 2000; }];
              }
              {
                # Permit English-dub releases as a fallback when a recognized
                # dual-audio release is unavailable.
                trash_ids = [ "9c14d194486c4014d422adc64092d794" ]; # Dubs Only
                assign_scores_to = [{ name = "Anime"; score = 0; }];
              }
            ];
          };
          radarr.radarr = {
            base_url = "http://127.0.0.1:7878";
            api_key = "!env_var RADARR_API_KEY";
            quality_definition.type = "movie";
            media_management.propers_and_repacks = "do_not_prefer";
            quality_profiles = [
              {
                trash_id = "fd161a61e3ab826d3a22d53f935696dd"; # Remux + WEB 2160p
                name = "Remux";
                reset_unmatched_scores.enabled = true;
              }
            ];
            custom_format_groups.add = [
              {
                trash_id = "a3ac6af01d78e4f21fcb75f601ac96df"; # [Unwanted] Unwanted Formats
                select = [
                  "b6832f586342ef70d9c128d40c07b872" # Bad Dual Groups
                  "ed38b889b31be83fda192888e2286d83" # BR-DISK
                  "90a6f9a284dff5103f6346090e6280c8" # LQ
                  "e204b80c87be9497a8a6eaff48f72905" # LQ (Release Title)
                  "bfd8eb01832d646a0a89c4deb46f8564" # Upscaled
                ];
              }
            ];
            custom_formats = [
              {
                # Reject CAM/TS releases with recorded theatre audio.
                trash_ids = [ "c465ccc73923871b3eb1802042331306" ]; # Line/Mic Dubbed
                assign_scores_to = [{ name = "Remux"; score = -10000; }];
              }
              {
                # Avoid Dolby Vision-only releases on players without DV support.
                trash_ids = [ "923b6abef9b17f937fab56cfcf89e1f1" ]; # DV (w/o HDR fallback)
                assign_scores_to = [{ name = "Remux"; score = -10000; }];
              }
            ];
          };
        };
      };
    };

    # Nixarr's API synchronizers communicate over loopback. Keep Forms auth for
    # remote UI access while bypassing it only for local service-to-service API calls.
    services.prowlarr.settings.auth.required = "DisabledForLocalAddresses";
    services.sonarr.settings.auth.required = "DisabledForLocalAddresses";
    services.radarr.settings.auth.required = "DisabledForLocalAddresses";

    # SABnzbd: fully declarative config on nixpkgs 26.05.
    #
    # configFile = null switches the nixpkgs module from the deprecated
    # self-managed ini to declarative `settings` (read-only, since
    # allowConfigWrite defaults to false on 26.05). The nixarr sabnzbd
    # module already populates settings.misc.{download_dir,complete_dir,
    # dirscan_dir,host,port,host_whitelist}; here we add the non-secret
    # categories + server scaffolding.
    #
    # Secrets (api_key, nzb_key, web login, news-server credentials) are NOT
    # in git. They live in a stateful host file at
    # /var/lib/sabnzbd-secrets/secrets.ini, merged at runtime via secretFiles
    # (secret values take precedence). Manage that file by hand on h001; see
    # the format note below. This avoids putting any credentials in the repo.
    services.sabnzbd = {
      configFile = null;

      # Keep using the existing nixarr state location (history db, queue, rss,
      # totals) instead of the nixpkgs default /var/lib/sabnzbd. nixpkgs uses
      # this as systemd StateDirectory (relative to /var/lib), so a nested path
      # is fine and matches nixarr's old ${nixarr.stateDir}/sabnzbd.
      stateDir = "nixarr/state/sabnzbd";

      # Runtime secret overlay (host-managed, never in git). Must exist before
      # sabnzbd starts. Expected contents (configobj ini):
      #
      #   [misc]
      #   api_key = <...>
      #   nzb_key = <...>
      #   username = admin
      #   password = <...>
      #   [servers]
      #   [[news.newsdemon.com]]
      #   username = <...>
      #   password = <...>
      secretFiles = [ "/var/lib/sabnzbd-secrets/secrets.ini" ];

      settings = {
        # Non-secret news server fields; credentials come from secretFiles.
        servers."news.newsdemon.com" = {
          name = "news.newsdemon.com";
          displayname = "news.newsdemon.com";
          host = "news.newsdemon.com";
          port = 563;
          timeout = 60;
          connections = 8;
          ssl = true;
          ssl_verify = "allow injection"; # = 2 in sabnzbd ini
          enable = true;
          priority = 0;
        };

        categories = {
          "*" = { name = "*"; order = 0; pp = 3; script = "None"; priority = 0; };
          movies = { name = "movies"; order = 1; script = "Default"; priority = -100; };
          tv = { name = "tv"; order = 2; script = "Default"; priority = -100; };
          audio = { name = "audio"; order = 3; script = "Default"; priority = -100; };
          software = { name = "software"; order = 4; script = "Default"; priority = -100; };
          books = { name = "books"; order = 5; script = "Default"; priority = -100; };
        };
      };
    };

    services.nginx = lib.mkIf config.nixarr.enable {
      virtualHosts = {
        "${c.jellyfinDomain}" = {
          addSSL = true;
          sslCertificate = "/var/lib/acme/${fleet.global.domain}/fullchain.pem";
          sslCertificateKey = "/var/lib/acme/${fleet.global.domain}/key.pem";
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://127.0.0.1:${toString c.jellyfinPort}";
          };
        };
        "${c.jellyseerrDomain}" = {
          addSSL = true;
          sslCertificate = "/var/lib/acme/${fleet.global.domain}/fullchain.pem";
          sslCertificateKey = "/var/lib/acme/${fleet.global.domain}/key.pem";
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:${toString c.jellyseerrPort}";
          };
        };
      };
    };
  };
}
