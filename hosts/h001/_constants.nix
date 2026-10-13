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
    forgejo = {
      port = 3000;
      sshPort = 3032;
      uid = 115;
      gid = 115;
      dataDir = "/var/lib/forgejo";
      containerIp = "10.0.0.2";
      containerIp6 = "fc00::2";
      domain = "git.joshuabell.xyz";
    };

    zitadel = {
      port = 8080;
      dataDir = "/var/lib/zitadel";
      containerIp = "10.0.0.3";
      containerIp6 = "fc00::3";
      domain = "sso.joshuabell.xyz";
    };

    immich = {
      port = 2283;
      uid = 916;
      gid = 916;
      dataDir = "/drives/wd10/immich";
      varLibDir = "/var/lib/immich";
      containerIp = "10.0.0.4";
      containerIp6 = "fc00::4";
      domain = "photos.joshuabell.xyz";
    };

    dawarich = {
      port = 3001;
      uid = 977;
      gid = 977;
      redisUid = 976;
      redisGid = 976;
      dataDir = "/drives/wd10/dawarich";
      containerIp = "10.0.0.5";
      containerIp6 = "fc00::5";
      domain = "location.joshuabell.xyz";
    };

    paperless = {
      port = 28981;
      uid = 915;
      gid = 915;
      dataDir = "/drives/wd10/paperless";
      varLibDir = "/var/lib/paperless";
      containerIp = "10.0.0.7";
      containerIp6 = "fc00::7";
      domain = "docs.joshuabell.xyz";
    };

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

    beszelHub = {
      port = 8090;
    };

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
