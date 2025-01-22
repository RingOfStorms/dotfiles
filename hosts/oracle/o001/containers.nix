{
  config,
  ...
}:
{

  # NOTE some useful links
  # nixos containers: https://blog.beardhatcode.be/2020/12/Declarative-Nixos-Containers.html
  # https://nixos.wiki/wiki/NixOS_Containers
  options = {};

  imports = [
    ./containers/tests.nix
  ];

  config = {
    ## Give internet access
    # networking.nat.enable = true;
    # networking.nat.internalInterfaces = [ "ve-*" ];
    # networking.nat.externalInterface = "eth0";

    virtualisation.oci-containers.backend = "docker";

    security.acme.acceptTerms = true;
    security.acme.defaults.email = "admin@joshuabell.xyz";
    services.nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts = {
        "local.belljm.com" = {
          # enableACME = true;
          # forceSSL = true;
          locations."/".proxyPass = "http://${config.containers.wasabi.localAddress}:80";
        };
        "127.0.0.1" = {
          locations."/wasabi/" = {
            extraConfig = ''
              rewrite ^/wasabi/(.*) /$1 break;
            '';
            proxyPass = "http://${config.containers.wasabi.localAddress}:80/";
          };
          locations."/" = {
            return = "404"; # or 444 for drop
          };
        };
        "_" = {
          default = true;
          locations."/" = {
            return = "404"; # or 444 for drop
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
