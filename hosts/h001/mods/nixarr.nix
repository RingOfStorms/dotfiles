{
  config,
  lib,
  constants,
  fleet,
  inputs,
  ...
}:
let
  c = constants.services.nixarr;
in
{
  # Swap nixarr's sabnzbd module for the PR #132 version that supports the
  # nixpkgs 26.05 `services.sabnzbd.settings` API. See the nixarr-sabnzbd-fix
  # input in flake.nix. Remove both once #132 merges into nixarr main.
  disabledModules = [ "${inputs.nixarr}/nixarr/sabnzbd" ];
  imports = [ "${inputs.nixarr-sabnzbd-fix}/nixarr/sabnzbd/default.nix" ];

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
      seerr.enable = true; # request manager for media (was jellyseerr; renamed in nixarr)
      # seerr.vpn.enable = true; # NOTE makes it not able to communicate to *arr apps
      sabnzbd = {
        enable = true; # Usenet downloader
        # Accessed directly at http://h001.net.joshuabell.xyz:6336 (no nginx
        # proxy). openFirewall binds the GUI to 0.0.0.0 and opens port 6336;
        # whitelistHostnames must include the FQDN or sabnzbd refuses the
        # connection ("Refused connection with hostname ...").
        openFirewall = true;
        whitelistHostnames = [
          "h001"
          "h001.net.joshuabell.xyz"
        ];
      };
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

    # SABnzbd: fully declarative config on nixpkgs 26.05.
    #
    # configFile = null switches the nixpkgs module from the deprecated
    # self-managed ini to declarative `settings` (read-only, since
    # allowConfigWrite defaults to false on 26.05). The nixarr-sabnzbd-fix
    # module already populates settings.misc.{download_dir,complete_dir,
    # dirscan_dir,host,port,host_whitelist}; here we add the non-secret
    # categories + server scaffolding.
    #
    # Secrets (api_key, nzb_key, web login, news-server credentials) are NOT
    # in git. They live in a stateful host file at
    # /var/lib/sabnzbd-secrets/secrets.ini, merged at runtime via secretFiles
    # (secret values take precedence). Manage that file by hand on h001; see
    # the format note below. This avoids putting any credentials in the repo.
    services.sabnzbd = {
      configFile = null;

      # Runtime secret overlay (host-managed, never in git). Must exist before
      # sabnzbd starts. Expected contents (configobj ini):
      #
      #   [misc]
      #   api_key = <...>
      #   nzb_key = <...>
      #   username = admin
      #   password = <...>
      #   [servers]
      #   [[news.newsdemon.com]]
      #   username = <...>
      #   password = <...>
      secretFiles = [ "/var/lib/sabnzbd-secrets/secrets.ini" ];

      settings = {
        # Non-secret news server fields; credentials come from secretFiles.
        servers."news.newsdemon.com" = {
          name = "news.newsdemon.com";
          displayname = "news.newsdemon.com";
          host = "news.newsdemon.com";
          port = 563;
          timeout = 60;
          connections = 8;
          ssl = true;
          ssl_verify = "allow injection"; # = 2 in sabnzbd ini
          enable = true;
          priority = 0;
        };

        categories = {
          "*" = { name = "*"; order = 0; pp = 3; script = "None"; priority = 0; };
          movies = { name = "movies"; order = 1; script = "Default"; priority = -100; };
          tv = { name = "tv"; order = 2; script = "Default"; priority = -100; };
          audio = { name = "audio"; order = 3; script = "Default"; priority = -100; };
          software = { name = "software"; order = 4; script = "Default"; priority = -100; };
          books = { name = "books"; order = 5; script = "Default"; priority = -100; };
        };
      };
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
