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
  config,
  constants,
  fleet,
  lib,
  pkgs,
  ...
}:
let
  overlayIp = constants.host.overlayIp;
  # oauth2-proxy cookie/identity hygiene (containers/lib.nix, shared with routes.go).
  inherit (import ../../containers/lib.nix) nginxSnippets;
  # Same spec `fleet-edge dns-plan` reconciles (dns-records.nix publicSpec).
  publicSpecFile = pkgs.writeText "fleet-public-spec.json" (
    builtins.toJSON (import ./dns-records.nix { inherit fleet; }).publicSpec
  );
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
let
  dnsPlanWrapper = pkgs.writeShellScriptBin "fleet-dns-plan" ''
    set -euo pipefail
    if [ "$(id -u)" -ne 0 ]; then
      echo "fleet-dns-plan: must be run as root (reads the bunny API key file)" >&2
      exit 1
    fi
    exec ${lib.getExe config.services.fleet-edge.package} dns-plan \
      --spec ${publicSpecFile} \
      --key-file /var/lib/secrets_manager_hydrated/bunny_rw_dns_2026-03-15 \
      "$@"
  '';
in
{
  imports = [ inputs.fleet-edge.nixosModules.default ];

  environment.systemPackages = [
    dnsPlanWrapper
    config.services.fleet-edge.package
  ];

  services.fleet-edge = {
    enable = true;
    # Public expose authority (ROUTING-PLAN §8 step 7). Callers authenticate
    # as their own Zitadel machine user (the sec-agent login, same issuer
    # and project), allowed only by explicit sub from their overlay IP.
    overrides = {
      enable = true;
      specFile = publicSpecFile;
      target = "o002.${fleet.global.domain}";
      dns.tailnetServer = "${fleet.hosts.h005.overlayIp}:53";
      # By overlay IP so the pinned known_hosts line matches (ssh uses
      # StrictHostKeyChecking=yes with only this file).
      pushTarget = "root@${fleet.hosts.o002.overlayIp}";
      knownHosts = "${fleet.hosts.o002.overlayIp} ${fleet.hosts.o002.sshHostKey}";
      bunnyKeyFile = "/var/lib/secrets_manager_hydrated/bunny_rw_dns_2026-03-15";
      pushKeyFile = "/var/lib/secrets_manager_hydrated/edge_vhost_push_2026-10-24";
      zitadel = {
        inherit (config.ringofstorms.secrets.agent.zitadel) issuer projectId;
      };
      writers = lib.mapAttrs (host: sub: {
        inherit sub;
        peer = fleet.hosts.${host}.overlayIp;
      }) fleet.global.overrideWriters;
    };
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
      # PiKVMs (appliances, tag:lowtrust; not in fleet.nix). Self-signed certs.
      (net "PiKVM" "https://pikvm.net.${domain}"
        "https://api.iconify.design/mdi/monitor-share.svg?color=%237fb0e8"
        "KVM over IP (V4 Mini)"
        "tailnet"
      )
      (net "FleetKVM" "https://fleetkvm.net.${domain}"
        "https://api.iconify.design/mdi/monitor-share.svg?color=%237fb0e8"
        "Rack KVM over IP (V4 Plus)"
        "tailnet"
      )

      # icon from the route (containers/puzzles)
      (personal "Puzzles" "https://puzzles.${domain}" "" "Puzzles" "public")
      (personal "Location" "https://location.${domain}" "dawarich" "Dawarich" "public")
      (on "hass" (
        personal "Home Assistant" "http://hass.net.${domain}:8123" "home-assistant" "Smart Home (HA Yellow)"
          "tailnet"
      ))
    ];
    # /topology diagram: physical gear, cabling and the explanation panel.
    # Inventory hosts, container placement, public `via = edge` paths,
    # tailnet membership and the fleet-agent poll fan are derived by
    # fleet-edge itself; see hosts/h005/topology.nix.
    topology = import ./topology.nix { inherit fleet constants; };
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
      # Public expose API and placement registry (fleet-edge-overrides,
      # ROUTING-PLAN §8 step 7, containers/PLACEMENT-PLAN.md). /internal/*
      # is never proxied; both exports are loopback-only.
      locations."/api/overrides" = {
        proxyPass = "http://127.0.0.1:8098";
        extraConfig = ''
          deny 100.64.0.5;
          deny fd7a:115c:a1e0::5;
          allow 100.64.0.0/10;
          allow fd7a:115c:a1e0::/48;
          deny all;
          # The only peer identity the service trusts (it ignores this
          # header unless the TCP peer is loopback).
          proxy_set_header X-Fleet-Peer $remote_addr;
          client_max_body_size 16k;
          proxy_read_timeout 180s;
          ${nginxSnippets.identityClear}
        '';
      };
      locations."/api/placements" = {
        proxyPass = "http://127.0.0.1:8098";
        extraConfig = ''
          deny 100.64.0.5;
          deny fd7a:115c:a1e0::5;
          allow 100.64.0.0/10;
          allow fd7a:115c:a1e0::/48;
          deny all;
          proxy_set_header X-Fleet-Peer $remote_addr;
          client_max_body_size 16k;
          proxy_read_timeout 180s;
          ${nginxSnippets.identityClear}
        '';
      };
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
