# fleet-edge read-only dashboard (containers/ROUTING-PLAN.md §5.4).
# The inventory is generated at build time from the containers flake, so it
# only refreshes when h005 is redeployed (`nix flake update containers` first).
#
# Tailnet-only: nginx listens on h005's overlay IP alone (plain HTTP, no
# public DNS, not proxied by o002) and additionally allows only tailnet
# source ranges. URL: http://h005.net.joshuabell.xyz/ (MagicDNS).
#
# Start page: replaces the homepage-dashboard instances that used to run on
# h001 (h001.net/h001.local) and joe (now redirects here). `links` below is
# the ported h001 homepage content; links whose url matches an inventory
# route take over that route's tile (and show its polled state). Remaining
# inventory routes appear under "Fleet services".
{
  inputs,
  constants,
  fleet,
  pkgs,
  ...
}:
let
  overlayIp = constants.host.overlayIp;
  domain = fleet.global.domain;
  h001 = "http://h001.net.${domain}";
  link = group: name: url: icon: description: {
    inherit
      group
      name
      url
      icon
      description
      ;
  };
  apps = link "Public Apps";
  media = link "Media";
  docs = link "Photos & Docs";
  ident = link "Identity & Security";
  net = link "Network";
  ai = link "AI";
in
{
  imports = [ inputs.fleet-edge.nixosModules.default ];

  services.fleet-edge = {
    enable = true;
    inventoryFile = pkgs.writeText "fleet-inventory.json" (builtins.toJSON inputs.containers.inventory);
    title = "Josh's Homelab";
    background = "https://w.wallhaven.cc/full/k9/wallhaven-k912lq.png";
    links = [
      (apps "Git" "https://git.${domain}" "forgejo" "Forgejo")
      (apps "Gist" "https://gist.${domain}" "opengist" "Opengist")
      (apps "Open WebUI" "https://chat.${domain}" "open-webui" "LLM Chats")
      (apps "Puzzles" "https://puzzles.${domain}" "" "Puzzles")

      (media "Jellyfin" "https://jellyfin.${domain}" "jellyfin" "Media Streaming")
      (media "Jellyseerr" "https://media.${domain}" "jellyseerr" "Media Requests")
      (media "Radarr" "${h001}:7878" "radarr" "Movie Automation")
      (media "Sonarr" "${h001}:8989" "sonarr" "Show Automation")
      (media "Bazarr" "${h001}:6767" "bazarr" "Subtitle Automation")
      (media "Prowlarr" "${h001}:9696" "prowlarr" "Indexer Manager")
      (media "SABnzbd" "${h001}:6336" "sabnzbd" "Usenet Downloader")
      (media "Transmission" "${h001}:9091" "transmission" "Torrent Downloader")
      (media "Shelfmark" "${h001}:8087" "shelfmark" "Books & Audiobooks")
      (media "Kavita" "https://books.${domain}" "kavita" "Ebook Library")
      (media "Audiobookshelf" "${h001}:9292" "audiobookshelf" "Audiobooks & Podcasts")
      (media "Media Integrity" "${h001}/media-health/" "" "FFmpeg Integrity Report")

      (docs "Photos" "https://photos.${domain}" "immich" "Immich")
      (docs "Docs" "https://docs.${domain}" "paperless-ngx" "Paperless-ngx")
      (docs "Notes" "https://notes.${domain}" "trilium-notes" "Trilium")
      (docs "Location" "https://location.${domain}" "dawarich" "Dawarich")

      (ident "SSO" "https://sso.${domain}" "zitadel" "Zitadel")
      (ident "Secrets" "https://secrets.${domain}" "" "Secrets Manager")

      (net "AdGuard Home" "http://h003.net.${domain}:3000" "adguard-home" "Network-wide Ad-blocker")
      (net "Beszel" "${h001}:8090" "beszel" "Server Metrics")

      # was joe's homepage (its only tile)
      (ai "LocalAI" "https://localai.ts.${domain}" "" "Image generation + TTS API (joe)")
    ];
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts.fleet = {
      default = true;
      serverName = "h005.net.joshuabell.xyz";
      listen = [
        {
          addr = overlayIp;
          port = 80;
        }
      ];
      locations."/" = {
        proxyPass = "http://127.0.0.1:8099";
        extraConfig = ''
          allow 100.64.0.0/10;
          allow fd7a:115c:a1e0::/48;
          deny all;
        '';
      };
    };
  };

  # nginx listens on the overlay IP, which only exists once tailscaled has
  # brought the tailnet up and may not exist yet when nginx starts at boot.
  # Ordering after tailscaled is not enough (the address comes later), so
  # allow binding addresses not (yet) assigned to any interface.
  # (IPFreeBind is not a service directive; systemd ignores it.)
  boot.kernel.sysctl = {
    "net.ipv4.ip_nonlocal_bind" = 1;
    "net.ipv6.ip_nonlocal_bind" = 1;
  };
  systemd.services.nginx = {
    wants = [ "tailscaled.service" ];
    after = [ "tailscaled.service" ];
  };
}
