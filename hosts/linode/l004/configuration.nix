{
  config,
  ...
}:
{
  boot.loader.grub.enable = true;
  system.stateVersion = "24.11";

  containers.wasabi = {
    ephemeral = true;
    autoStart = true;
    privateNetwork = true;
    hostAddress = "192.168.100.2";
    localAddress = "192.168.100.11";
    config =
      { config, pkgs, ... }:
      {
        system.stateVersion = "24.11";
        services.httpd.enable = true;
        services.httpd.adminAddr = "foo@example.org";
        networking.firewall = {
          enable = true;
          allowedTCPPorts = [ 80 ];
        };
      };
  };

  virtualisation.oci-containers = {
    backend = "docker"; # or "podman"
    containers = {
      # Example of defining a container from the compose file
      "test_nginx" = {
        # autoStart = true; this is default true
        image = "nginx:latest";
        ports = [
          "127.0.0.1:8085:80"
        ];
      };
    };
  };

  security.acme.acceptTerms = true;
  security.acme.email = "admin@joshuabell.xyz";
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    virtualHosts = {
      "_" = {
        default = true;
        locations."/wasabi/" = {
          extraConfig = ''
            rewrite ^/wasabi/(.*) /$1 break;
          '';
          proxyPass = "http://${config.containers.wasabi.localAddress}:80/";
        };
        locations."/" = {
          # return = "404"; # or 444 for drop
          proxyPass = "http://127.0.0.1:8085/";
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
