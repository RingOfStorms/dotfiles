# Service constants for h001 (Service Host)
# Single source of truth for ports, UIDs/GIDs, data paths, container IPs, and domains.
# Import this file in flake.nix and pass to service modules via specialArgs or let bindings.
{ fleet }:
{
  # Host-level
  host = {
    name = "h001";
    overlayIp = "100.64.0.13";
    lanIp = "10.12.14.10";
    primaryUser = "luser";
    stateVersion = "24.11";
  };

  # Container network (shared host address for all NixOS containers)
  containerNetwork = {
    hostAddress = "10.0.0.1";
    hostAddress6 = "fc00::1";
  };

  services = {
    forgejo.domain = "git.joshuabell.xyz"; # floating container (containers/forgejo)

    zitadel = {
      port = 8080;
      dataDir = "/var/lib/zitadel";
      containerIp = "10.0.0.3";
      containerIp6 = "fc00::3";
      domain = "sso.joshuabell.xyz";
    };

    immich.domain = "photos.joshuabell.xyz"; # floating container (containers/immich)

    dawarich.domain = "location.joshuabell.xyz"; # floating container (containers/dawarich)

    paperless.domain = "docs.joshuabell.xyz"; # floating container (containers/paperless)

    # Floating container: containers/opengist (port, vhost live there).
    opengist = {
      domain = "gist.joshuabell.xyz";
    };

    # Floating containers: containers/{life,litellm,open-webui,searx,trilium,puzzles}
    # (ports, vhosts live there). Domains kept for the homepage tiles.
    openWebui = {
      domain = "chat.joshuabell.xyz";
    };

    trilium = {
      domain = "notes.joshuabell.xyz";
    };

    beszelHub.port = 8090; # floating container (containers/beszel), tailnet IP only

    # `sec` — the secrets manager server. Runs on h001 (port 8300,
    # secrets.joshuabell.xyz). Replaced the old OpenBao server that used to
    # run here.
    sec = {
      port = 8300;
      dataDir = "/var/lib/secrets_manager";
      # Single-label, so the existing *.joshuabell.xyz wildcard cert
      # covers it with no extraDomainNames entry.
      domain = "secrets.joshuabell.xyz";
    };

    homepage = {
      port = 8082;
    };

    mediaIntegrity = {
      dataDir = "/var/lib/media-integrity";
      webPath = "/media-health/";
      scanSubdirectories = [ "library/movies" ];
      extensions = [
        ".avi"
        ".flv"
        ".m2ts"
        ".m4v"
        ".mkv"
        ".mov"
        ".mp4"
        ".mpeg"
        ".mpg"
        ".mts"
        ".ogv"
        ".ts"
        ".vob"
        ".webm"
        ".wmv"
      ];
      onCalendar = "Sun *-*-* 03:00:00";
      randomizedDelay = "30m";
      perFileTimeoutSec = 43200;
    };

    puzzles = {
      domain = "puzzles.joshuabell.xyz";
    };

    nixarr = {
      containerName = "arr";
      jellyfinPort = 8096;
      jellyseerrPort = 5055;
      shelfmarkPort = 8087;
      audiobookshelfPort = 9292;
      kavitaPort = 5000;
      transmissionPeerPort = 51820;
      mediaDir = "/nfs/h002/nixarr/media";
      stateDir = "/var/lib/nixarr/state";
      jellyfinDomain = "jellyfin.joshuabell.xyz";
      jellyseerrDomain = "media.joshuabell.xyz";
    };
  };

}
