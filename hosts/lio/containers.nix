{ inputs }:
let
  common = inputs.common;
  nixarr = inputs.nixarr;
in
{
  config,
  ...
}:
{
  # NOTE some useful links
  # nixos containers: https://blog.beardhatcode.be/2020/12/Declarative-Nixos-Containers.html
  # https://nixos.wiki/wiki/NixOS_Containers
  options = { };

  imports = [
    common.nixosModules.containers.librechat
    common.nixosModules.containers.obsidian_sync
  ];

  config = {
    # Obsidian Sync settings
    services.obsidian_sync = {
      serverUrl = "https://obsidiansync.joshuabell.xyz";
      dockerEnvFiles = [ config.age.secrets.obsidian_sync_env.path ];
    };

    ## Give internet access
    networking = {
      nat = {
        enable = true;
        internalInterfaces = [ "ve-*" ];
        externalInterface = "eno1";
        enableIPv6 = true;
      };
      firewall.trustedInterfaces = [ "ve-*" ];
    };

    # containers.nixarr =
    #   let
    #     name = "nixarr";
    #     # hostDataDir = "/var/lib/${name}";
    #     hostAddress = "10.0.0.1";
    #     containerAddress = "10.0.0.3";
    #     hostAddress6 = "fc00::1";
    #     containerAddress6 = "fc00::3";
    #   in
    #   {
    #     ephemeral = true;
    #     autoStart = true;
    #     privateNetwork = true;
    #     hostAddress = hostAddress;
    #     localAddress = containerAddress;
    #     hostAddress6 = hostAddress6;
    #     localAddress6 = containerAddress6;
    #     config =
    #       { config, pkgs, ... }:
    #       {
    #         imports = [
    #           nixarr.nixosModules.default
    #         ];
    #         system.stateVersion = "25.05";
    #         nixpkgs.config.allowUnfree = true;
    #
    #         nixarr = {
    #           enable = true;
    #           # These two values are also the default, but you can set them to whatever
    #           # else you want
    #           # WARNING: Do _not_ set them to `/home/user/whatever`, it will not work!
    #           mediaDir = "/var/lib/nixarr_test/media";
    #           stateDir = "/var/lib/nixarr_test/state";
    #
    #           # vpn = {
    #           #   enable = true;
    #           #   # WARNING: This file must _not_ be in the config git directory
    #           #   # You can usually get this wireguard file from your VPN provider
    #           #   wgConf = "/data/.secret/wg.conf";
    #           # };
    #
    #           jellyfin = {
    #             enable = true;
    #             # These options set up a nginx HTTPS reverse proxy, so you can access
    #             # Jellyfin on your domain with HTTPS
    #             # expose.https = {
    #             #   enable = true;
    #             #   domainName = "your.domain.com";
    #             #   acmeMail = "your@email.com"; # Required for ACME-bot
    #             # };
    #           };
    #
    #           # transmission = {
    #           #   enable = true;
    #           #   vpn.enable = true;
    #           #   peerPort = 50000; # Set this to the port forwarded by your VPN
    #           # };
    #
    #           # It is possible for this module to run the *Arrs through a VPN, but it
    #           # is generally not recommended, as it can cause rate-limiting issues.
    #           sabnzbd.enable = true; # Usenet downloader
    #           prowlarr.enable = true; # Index manager
    #           sonarr.enable = true; # TV
    #           radarr.enable = true; # Movies
    #           bazarr.enable = true; # subtitles for sonarr and radarr
    #           lidarr.enable = true; # music
    #           readarr.enable = true; # books
    #           jellyseerr.enable = true; # request manager for media
    #         };
    #       };
    #   };

    # containers.wasabi = {
    #   ephemeral = true;
    #   autoStart = true;
    #   privateNetwork = true;
    #   hostAddress = "10.0.0.1";
    #   localAddress = "10.0.0.111";
    #   config =
    #     { config, pkgs, ... }:
    #     {
    #       system.stateVersion = "24.11";
    #       services.httpd.enable = true;
    #       services.httpd.adminAddr = "foo@example.org";
    #       networking.firewall = {
    #         enable = true;
    #         allowedTCPPorts = [ 80 ];
    #       };
    #     };
    # };

    # virtualisation.oci-containers.containers = {
    #   ntest = {
    #     image = "nginx:alpine";
    #     ports = [
    #       "127.0.0.1:8085:80"
    #     ];
    #   };
    # };

    virtualisation.oci-containers.backend = "docker";

    services.nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts = {
        "_" = {
          default = true;
          locations."/" = {
            return = "444"; # or 444 for drop
          };
        };
      };
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
