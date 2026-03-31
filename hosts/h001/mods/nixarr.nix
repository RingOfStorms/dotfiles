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
        # wgConf injected via secrets-bao configChanges
      };

      jellyfin.enable = true; # jellyfinnnnnn!
      jellyfin.vpn.enable = true;
      jellyseerr.enable = true; # request manager for media
      # jellyseerr.vpn.enable = true; # NOTE makes it not able to communicate to *arr apps
      sabnzbd.enable = true; # Usenet downloader
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
          rpc-username = "transmission";
          rpc-password = "transmission";
          rpc-host-whitelist-enabled = false;
          rpc-whitelist-enabled = false;
          rpc-whitelist = "127.0.0.1,::1,192.168.1.71,100.64.0.0/10";
        };
      };
      prowlarr.enable = true; # Index manager
      sonarr.enable = true; # TV
      radarr.enable = true; # Movies
      bazarr.enable = true; # subtitles for sonarr and radarr
      lidarr.enable = false; # music
      # recyclarr.enable = true; # not sure how to use this yet
    };

    services.nginx = lib.mkIf config.nixarr.enable {
      virtualHosts = {
        "${c.jellyfinDomain}" = {
          addSSL = true;
          sslCertificate = "/var/lib/acme/${fleet.global.domain}/fullchain.pem";
          sslCertificateKey = "/var/lib/acme/${fleet.global.domain}/key.pem";
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:${toString c.jellyfinPort}";
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
