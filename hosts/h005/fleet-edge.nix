# fleet-edge read-only dashboard (containers/ROUTING-PLAN.md §5.4).
# The inventory is generated at build time from the containers flake, so it
# only refreshes when h005 is redeployed (`nix flake update containers` first).
#
# Tailnet-only: nginx listens on h005's overlay IP alone (plain HTTP, no
# public DNS, not proxied by o002) and additionally allows only tailnet
# source ranges. URL: http://h005.net.joshuabell.xyz/ (MagicDNS).
#
# Start page: replaces the homepage-dashboard instances that used to run on
# h001 and joe (retired, no redirects left). `links` below is the ported
# h001 homepage content; `host` pins the serving host for links the URL
# can't be traced to (public vhosts proxied to h001); links whose url matches an inventory
# route take over that route's tile (and show its polled state). Remaining
# inventory routes appear under their route `group` (containers/<svc>/service.nix).
{
  inputs,
  constants,
  fleet,
  pkgs,
  ...
}:
let
  overlayIp = constants.host.overlayIp;
  # oauth2-proxy cookie/identity hygiene (containers/lib.nix, shared with routes.go).
  inherit (import ../../containers/lib.nix) nginxSnippets;
  domain = fleet.global.domain;
  h001 = "http://h001.net.${domain}";
  link = group: name: url: icon: description: exposure: {
    inherit
      group
      name
      url
      icon
      description
      exposure
      ;
  };
  # explicit serving host for public vhosts the URL can't be traced to
  on = host: l: l // { inherit host; };
  media = link "Media";
  arr = link "Media Automation";
  prod = link "Productivity";
  ident = link "Identity & Security";
  net = link "Network";
  ai = link "AI";
  personal = link "Personal";
in
{
  imports = [ inputs.fleet-edge.nixosModules.default ];

  services.fleet-edge = {
    enable = true;
    inventoryFile = pkgs.writeText "fleet-inventory.json" (builtins.toJSON inputs.containers.inventory);
    title = "Josh's Homelab";
    background = "https://w.wallhaven.cc/full/k9/wallhaven-k912lq.png";
    # exposure: badge for links that aren't inventory routes (a matching
    # route's exposure wins). Unclaimed routes use their own route group.
    links = [
      (on "h001" (media "Jellyfin" "https://jellyfin.${domain}" "jellyfin" "Media Streaming" "public"))
      (on "h001" (media "Jellyseerr" "https://media.${domain}" "jellyseerr" "Media Requests" "public"))
      (on "h001" (media "Kavita" "https://books.${domain}" "kavita" "Ebook Library" "public"))
      (media "Photos" "https://photos.${domain}" "immich" "Immich" "public")

      (arr "Radarr" "https://radarr.${domain}" "radarr" "Movie Automation" "tailnet")
      (arr "Sonarr" "https://sonarr.${domain}" "sonarr" "Show Automation" "tailnet")
      (arr "Bazarr" "https://bazarr.${domain}" "bazarr" "Subtitle Automation" "tailnet")
      (arr "Prowlarr" "https://prowlarr.${domain}" "prowlarr" "Indexer Manager" "tailnet")
      (arr "SABnzbd" "https://sabnzbd.${domain}" "sabnzbd" "Usenet Downloader" "tailnet")
      (arr "Transmission" "https://transmission.${domain}" "transmission" "Torrent Downloader" "tailnet")
      (on "h001" (
        arr "Shelfmark" "https://shelfmark.${domain}" "shelfmark" "Books & Audiobooks" "tailnet"
      ))
      (arr "Media Integrity" "${h001}/media-health/"
        "https://api.iconify.design/mdi/movie-check-outline.svg?color=%237fb0e8"
        "FFmpeg Integrity Report"
        "tailnet"
      )

      (prod "Docs" "https://docs.${domain}" "paperless-ngx" "Paperless-ngx" "tailnet")
      (on "h001" (prod "Notes" "https://notes.${domain}" "trilium-notes" "Trilium" "public"))
      (prod "Git" "https://git.${domain}" "forgejo" "Forgejo" "public")
      (prod "Gist" "https://gist.${domain}" "opengist" "Opengist" "public")

      (ident "SSO" "https://sso.${domain}" "zitadel" "Zitadel" "public")
      # icon from the route (containers/sec)
      (ident "Secrets" "https://secrets.${domain}" "" "Secrets Manager" "public")

      (ai "Open WebUI" "https://chat.${domain}" "open-webui" "LLM Chats" "public")
      # was joe's homepage (its only tile); icon from the route
      (ai "LocalAI" "https://localai.ts.${domain}" "" "Image generation + TTS API (joe)" "tailnet")

      # AdGuard runs on h005; its admin UI (:3000) is reachable from the LAN only.
      (net "AdGuard Home" "http://${constants.network.vlans.lan.ipv4}:3000" "adguard-home"
        "Ad-blocker (LAN only)"
        "lan"
      )
      (on "h005" (
        net "Fleet Edge" "https://fleet.${domain}/"
          "https://api.iconify.design/mdi/view-dashboard-outline.svg?color=%237fb0e8"
          "This dashboard: routes + host health"
          "tailnet"
      ))

      # icon from the route (containers/puzzles)
      (personal "Puzzles" "https://puzzles.${domain}" "" "Puzzles" "public")
      (personal "Location" "https://location.${domain}" "dawarich" "Dawarich" "public")
    ];
    auth.zitadel = {
      enable = true;
      issuer = "https://sso.${domain}";
      projectId = "396290770694311170";
      clientId = "396291132042054914";
      redirectUri = "https://fleet.${domain}/auth/callback";
      allowedRole = "admin";
    };
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."fleet.${domain}" = {
      default = true;
      serverName = "fleet.${domain}";
      serverAliases = [ "h005.net.${domain}" ];
      useACMEHost = if constants.network.routerEnable then domain else null;
      forceSSL = constants.network.routerEnable;
      extraConfig = nginxSnippets.cookieStrip;
      listen = [
        {
          addr = overlayIp;
          port = 80;
        }
      ]
      ++ (
        if constants.network.routerEnable then
          [
            {
              addr = overlayIp;
              port = 443;
              ssl = true;
            }
          ]
        else
          [ ]
      );
      locations."/" = {
        proxyPass = "http://127.0.0.1:8099";
        extraConfig = ''
          # o002 (public edge) counts as the internet
          deny 100.64.0.5;
          deny fd7a:115c:a1e0::5;
          allow 100.64.0.0/10;
          allow fd7a:115c:a1e0::/48;
          deny all;
          ${nginxSnippets.identityClear}
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
