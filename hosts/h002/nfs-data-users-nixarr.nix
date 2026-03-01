{ lib, config, constants, ... }:
# This file sets up perms for MEDIA only (not state dirs) on this system since we are running nixarr on another host but NFS mounting the data drive from here.
let
  globals = config.util-nixarr.globals;
  nixarr = {
    mediaDir = constants.services.nixarr.mediaDir;
  };

  pinchflatMediaDir = constants.services.pinchflat.mediaDir;
  pinchflat = true;
  pinchflatId = constants.services.pinchflat.uid;

  # Matches up to my h001/mods/nixarr|pinchflat.nix files
  audiobookshelf = false;
  jellyfin = true;
  komga = false;
  lidarr = false;
  plex = false;
  radarr = true;
  readarr-audiobook = false;
  readarr = false;
  sabnzbd = true;
  sonarr = true;
  transmission = true;
  whisparr = false;
in
lib.mkMerge [
  (lib.mkIf pinchflat {
    users = {
      groups.pinchflat.gid = constants.services.pinchflat.gid;
      users.pinchflat = {
        isSystemUser = true;
        group = "pinchflat";
        uid = pinchflatId;
      };
    };

    systemd.tmpfiles.rules = [
      "d '${pinchflatMediaDir}' 0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
    ];
  })
  (lib.mkIf audiobookshelf {
    users = {
      groups.${globals.audiobookshelf.group}.gid = globals.gids.${globals.audiobookshelf.group};
      users.${globals.audiobookshelf.user} = {
        isSystemUser = true;
        group = globals.audiobookshelf.group;
        uid = globals.uids.${globals.audiobookshelf.user};
      };
    };

    systemd.tmpfiles.rules = [
      "d '${nixarr.mediaDir}/library/audiobooks'  0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/podcasts'    0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
    ];
  })
  (lib.mkIf jellyfin {
    users = {
      groups.${globals.jellyfin.group}.gid = globals.gids.${globals.jellyfin.group};
      users.${globals.jellyfin.user} = {
        isSystemUser = true;
        group = globals.jellyfin.group;
        uid = globals.uids.${globals.jellyfin.user};
      };
    };

    systemd.tmpfiles.rules = [
      "d '${nixarr.mediaDir}/library'             0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/shows'       0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/movies'      0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/music'       0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/books'       0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/audiobooks'  0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
    ];
  })
  (lib.mkIf komga {
    users = {
      groups.${globals.komga.group}.gid = globals.gids.${globals.komga.group};
      users.${globals.komga.user} = {
        isSystemUser = true;
        group = globals.komga.group;
        uid = globals.uids.${globals.komga.user};
      };
    };

    systemd.tmpfiles.rules = [
      "d '${nixarr.mediaDir}/library'             0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/books'       0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
    ];
  })
  (lib.mkIf lidarr {
    users = {
      groups.${globals.lidarr.group}.gid = globals.gids.${globals.lidarr.group};
      users.${globals.lidarr.user} = {
        isSystemUser = true;
        group = globals.lidarr.group;
        uid = globals.uids.${globals.lidarr.user};
      };
    };

    systemd.tmpfiles.rules = [
      "d '${nixarr.mediaDir}/library'        0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/music'  0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
    ];
  })
  (lib.mkIf plex {
    users = {
      groups.${globals.plex.group}.gid = globals.gids.${globals.plex.group};
      users.${globals.plex.user} = {
        isSystemUser = true;
        group = globals.plex.group;
        uid = globals.uids.${globals.plex.user};
      };
    };

    systemd.tmpfiles.rules = [
      "d '${nixarr.mediaDir}/library'             0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/shows'       0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/movies'      0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/music'       0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/books'       0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/audiobooks'  0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
    ];
  })
  (lib.mkIf radarr {
    systemd.tmpfiles.rules = [
      "d '${nixarr.mediaDir}/library'        0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/movies' 0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
    ];

    users = {
      groups.${globals.radarr.group}.gid = globals.gids.${globals.radarr.group};
      users.${globals.radarr.user} = {
        isSystemUser = true;
        group = globals.radarr.group;
        uid = globals.uids.${globals.radarr.user};
      };
    };
  })
  (lib.mkIf readarr-audiobook {
    users = {
      groups.${globals.readarr-audiobook.group}.gid = globals.gids.${globals.readarr-audiobook.group};
      users.${globals.readarr-audiobook.user} = {
        isSystemUser = true;
        group = globals.readarr-audiobook.group;
        uid = globals.uids.${globals.readarr-audiobook.user};
      };
    };

    systemd.tmpfiles.rules = [
      "d '${nixarr.mediaDir}/library'             0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/audiobooks'  0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
    ];
  })
  (lib.mkIf readarr {
    users = {
      groups.${globals.readarr.group}.gid = globals.gids.${globals.readarr.group};
      users.${globals.readarr.user} = {
        isSystemUser = true;
        group = globals.readarr.group;
        uid = globals.uids.${globals.readarr.user};
      };
    };

    systemd.tmpfiles.rules = [
      "d '${nixarr.mediaDir}/library'       0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/books' 0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
    ];
  })
  (lib.mkIf sabnzbd {
    users = {
      groups.${globals.sabnzbd.group}.gid = globals.gids.${globals.sabnzbd.group};
      users.${globals.sabnzbd.user} = {
        isSystemUser = true;
        group = globals.sabnzbd.group;
        uid = globals.uids.${globals.sabnzbd.user};
      };
    };

    systemd.tmpfiles.rules = [
      "d '${nixarr.mediaDir}/usenet'             0755 ${globals.sabnzbd.user} ${globals.sabnzbd.group} - -"
      "d '${nixarr.mediaDir}/usenet/.incomplete' 0755 ${globals.sabnzbd.user} ${globals.sabnzbd.group} - -"
      "d '${nixarr.mediaDir}/usenet/.watch'      0755 ${globals.sabnzbd.user} ${globals.sabnzbd.group} - -"
      "d '${nixarr.mediaDir}/usenet/manual'      0775 ${globals.sabnzbd.user} ${globals.sabnzbd.group} - -"
      "d '${nixarr.mediaDir}/usenet/lidarr'      0775 ${globals.sabnzbd.user} ${globals.sabnzbd.group} - -"
      "d '${nixarr.mediaDir}/usenet/radarr'      0775 ${globals.sabnzbd.user} ${globals.sabnzbd.group} - -"
      "d '${nixarr.mediaDir}/usenet/sonarr'      0775 ${globals.sabnzbd.user} ${globals.sabnzbd.group} - -"
      "d '${nixarr.mediaDir}/usenet/readarr'     0775 ${globals.sabnzbd.user} ${globals.sabnzbd.group} - -"
    ];
  })
  (lib.mkIf sonarr {
    users = {
      groups.${globals.sonarr.group}.gid = globals.gids.${globals.sonarr.group};
      users.${globals.sonarr.user} = {
        isSystemUser = true;
        group = globals.sonarr.group;
        uid = globals.uids.${globals.sonarr.user};
      };
    };

    systemd.tmpfiles.rules = [
      "d '${nixarr.mediaDir}/library'        0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/shows'  0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
    ];
  })
  (lib.mkIf transmission {
    users = {
      groups.${globals.transmission.group}.gid = globals.gids.${globals.transmission.group};
      users.${globals.transmission.user} = {
        isSystemUser = true;
        group = globals.transmission.group;
        uid = globals.uids.${globals.transmission.user};
      };
    };

    systemd.tmpfiles.rules = [
      "d '${nixarr.mediaDir}/torrents'             0755 ${globals.transmission.user} ${globals.transmission.group} - -"
      "d '${nixarr.mediaDir}/torrents/.incomplete' 0755 ${globals.transmission.user} ${globals.transmission.group} - -"
      "d '${nixarr.mediaDir}/torrents/.watch'      0755 ${globals.transmission.user} ${globals.transmission.group} - -"
      "d '${nixarr.mediaDir}/torrents/manual'      0755 ${globals.transmission.user} ${globals.transmission.group} - -"
      "d '${nixarr.mediaDir}/torrents/lidarr'      0755 ${globals.transmission.user} ${globals.transmission.group} - -"
      "d '${nixarr.mediaDir}/torrents/radarr'      0755 ${globals.transmission.user} ${globals.transmission.group} - -"
      "d '${nixarr.mediaDir}/torrents/sonarr'      0755 ${globals.transmission.user} ${globals.transmission.group} - -"
      "d '${nixarr.mediaDir}/torrents/readarr'     0755 ${globals.transmission.user} ${globals.transmission.group} - -"
    ];
  })
  (lib.mkIf whisparr {
    users = {
      groups.${globals.whisparr.group}.gid = globals.gids.${globals.whisparr.group};
      users.${globals.whisparr.user} = {
        isSystemUser = true;
        group = globals.whisparr.group;
        uid = globals.uids.${globals.whisparr.user};
      };
    };

    systemd.tmpfiles.rules = [
      "d '${nixarr.mediaDir}/library'        0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      "d '${nixarr.mediaDir}/library/xxx'    0775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
    ];
  })
]
