{
  ...
}:
{
  config = {
    nixarr = {
      enable = true;
      mediaDir = "/var/lib/nixarr/media";
      stateDir = "/var/lib/nixarr/state";

      jellyfin.enable = true; # jellyfinnnnnn!
      sabnzbd.enable = true; # Usenet downloader
      prowlarr.enable = true; # Index manager
      sonarr.enable = true; # TV
      radarr.enable = true; # Movies
      bazarr.enable = true; # subtitles for sonarr and radarr
      lidarr.enable = true; # music
      readarr.enable = true; # books
      jellyseerr.enable = true; # request manager for media
    };
  };
}
