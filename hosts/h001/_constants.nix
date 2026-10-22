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

  services = {
    forgejo.domain = "git.joshuabell.xyz"; # floating container (containers/forgejo)

    zitadel.domain = "sso.joshuabell.xyz"; # floating container (containers/zitadel)

    immich.domain = "photos.joshuabell.xyz"; # floating container (containers/immich)

    dawarich.domain = "location.joshuabell.xyz"; # floating container (containers/dawarich)

    paperless.domain = "docs.joshuabell.xyz"; # floating container (containers/paperless)

    # Floating container: containers/opengist (port, vhost live there).
    opengist = {
      domain = "gist.joshuabell.xyz";
    };

    # Floating containers: containers/{life,litellm,open-webui,searx,trilium,puzzles}
    # (ports, vhosts live there). Domains kept for reference.
    openWebui = {
      domain = "chat.joshuabell.xyz";
    };

    trilium = {
      domain = "notes.joshuabell.xyz";
    };

    sec.domain = "secrets.joshuabell.xyz"; # floating container (containers/sec)

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
      kavitaPort = 5000;
      transmissionPeerPort = 51820;
      mediaDir = "/nfs/h002/nixarr/media";
      stateDir = "/var/lib/nixarr/state";
      jellyfinDomain = "jellyfin.joshuabell.xyz";
      jellyseerrDomain = "media.joshuabell.xyz";
    };
  };

}
