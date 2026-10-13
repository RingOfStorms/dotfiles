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

    matrix = {
      synapsePort = 8008;
      elementPort = 80;
      serverName = "matrix.joshuabell.xyz";
      elementDomain = "element.joshuabell.xyz";
      dataDir = "/var/lib/matrix";
      containerIp = "10.0.0.6";
      # UIDs/GIDs for services inside the matrix container
      postgresUid = 71;
      postgresGid = 71;
      synapseUid = 198;
      synapseGid = 198;
      bridges = {
        gmessages = {
          port = 29336;
          uid = 992;
          gid = 992;
          enabled = true;
        };
        signal = {
          port = 29328;
          uid = 991;
          gid = 991;
          enabled = true;
        };
        discord = {
          port = 29334;
          uid = 987;
          gid = 987;
          enabled = true;
        };
        instagram = {
          port = 29320;
          uid = 990;
          gid = 985;
          enabled = false;
        };
        facebook = {
          port = 29321;
          uid = 989;
          gid = 985;
          enabled = false;
        };
        whatsapp = {
          port = 29318;
          uid = 988;
          gid = 988;
          enabled = true;
        };
        telegram = {
          port = 29317;
          uid = 986;
          gid = 986;
          enabled = false;
        };
      };
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

    # Life — personal life server (Rust server serving its own web client) with
    # its own PostgreSQL 18 inside one NixOS container. The application and its
    # NixOS module come from the life repo's flake; this host supplies the
    # container, the bind mounts and the vhost.
    life = {
      port = 8080;
      uid = 917;
      gid = 917;
      dataDir = "/var/lib/life";
      containerIp = "10.0.0.12";
      containerIp6 = "fc00::12";
      domain = "life.joshuabell.xyz";
    };

    litellm = {
      port = 8094;
      dataDir = "/var/lib/litellm";
      domain = null; # No public domain, accessed via Tailscale
    };

    openWebui = {
      port = 8084;
      domain = "chat.joshuabell.xyz";
    };

    searx = {
      port = 8889;
    };

    trilium = {
      port = 9111;
      overlayPort = 9112;
      dataDir = "/var/lib/trilium";
      domain = "notes.joshuabell.xyz";
    };

    oauth2Proxy = {
      port = 4180;
      domain = "sso-proxy.joshuabell.xyz";
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
      port = 8093;
      domain = "puzzles.joshuabell.xyz";
    };

    etebase = {
      dataDir = "/var/lib/etebase-server";
      domain = "etebase.joshuabell.xyz";
      webDomain = "pim.joshuabell.xyz";
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
