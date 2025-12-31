{
  config,
  lib,
  ...
}:
let
  hasSecret =
    secret:
    let
      secrets = config.age.secrets or { };
    in
    secrets ? ${secret} && secrets.${secret} != null;
in
{
  config = {
    users.groups.media.gid = lib.mkForce 2000;

    # Make sure all media services can write to NFS mediaDir.
    users.users.sonarr.extraGroups = lib.mkAfter [ "media" ];
    users.users.radarr.extraGroups = lib.mkAfter [ "media" ];
    users.users.bazarr.extraGroups = lib.mkAfter [ "media" ];
    users.users.prowlarr.extraGroups = lib.mkAfter [ "media" ];
    users.users.lidarr.extraGroups = lib.mkAfter [ "media" ];
    users.users.jellyfin.extraGroups = lib.mkAfter [ "media" ];
    users.users.jellyseerr.extraGroups = lib.mkAfter [ "media" ];
    users.users.sabnzbd.extraGroups = lib.mkAfter [ "media" ];
    users.users.transmission.extraGroups = lib.mkAfter [ "media" ];

    users.users.pinchflat.extraGroups = lib.mkAfter [ "media" ];
    systemd.services.pinchflat.serviceConfig.UMask = "0002";

    systemd.services.sonarr.serviceConfig.UMask = "0002";
    systemd.services.radarr.serviceConfig.UMask = "0002";
    systemd.services.bazarr.serviceConfig.UMask = "0002";
    systemd.services.prowlarr.serviceConfig.UMask = "0002";
    systemd.services.lidarr.serviceConfig.UMask = "0002";
    systemd.services.jellyfin.serviceConfig.UMask = "0002";
    systemd.services.jellyseerr.serviceConfig.UMask = "0002";
    systemd.services.sabnzbd.serviceConfig.UMask = "0002";
    systemd.services.transmission.serviceConfig.UMask = "0002";

    nixarr = {
      enable = true;
      # mediaDir = "/drives/wd10/nixarr/media";
      mediaDir = "/nfs/h002/nixarr/media";
      stateDir = "/var/lib/nixarr/state";

      vpn = lib.mkIf (hasSecret "us_chi_wg") {
        enable = true;
        wgConf = config.age.secrets.us_chi_wg.path;
      };

      jellyfin.enable = true; # jellyfinnnnnn!
      jellyfin.vpn.enable = true;
      jellyseerr.enable = true; # request manager for media
      # jellyseerr.vpn.enable = true; # NOTE makes it not able to communicate to *arr apps
      sabnzbd.enable = true; # Usenet downloader
      transmission = {
        enable = true; # Torrent downloader
        vpn.enable = true;
        peerPort = 51820;
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
        "jellyfin.joshuabell.xyz" = {
          addSSL = true;
          sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
          sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:8096";
          };
        };
        "media.joshuabell.xyz" = {
          addSSL = true;
          sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
          sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://localhost:5055";
          };
        };
      };
    };
  };
}
