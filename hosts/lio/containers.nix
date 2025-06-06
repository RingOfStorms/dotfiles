{ common }:
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
    # common.nixosModules.containers.obsidian_sync
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
