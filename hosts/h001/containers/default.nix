{ common }:
{
  ...
}:
{
  imports = [
    # common.nixosModules.containers.librechat
    common.nixosModules.containers.forgejo
    ./opengist.nix
  ];

  config = {
    ## Give internet access
    networking = {
      nat = {
        enable = true;
        internalInterfaces = [ "ve-*" ];
        externalInterface = "enp0s31f6";
        enableIPv6 = true;
      };
      firewall.trustedInterfaces = [ "ve-*" ];
    };

    containers.wasabi = {
      ephemeral = true;
      autoStart = true;
      privateNetwork = true;
      hostAddress = "10.0.0.1";
      localAddress = "10.0.0.111";
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

    virtualisation.oci-containers.containers = {
      ntest = {
        image = "nginx:alpine";
        ports = [
          "127.0.0.1:8085:80"
        ];
      };
    };

    virtualisation.oci-containers.backend = "podman";

    services.nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts = {
        "localhost" = {
          locations."/" = {
            proxyPass = "http://10.0.0.111";
          };
        };

        "git.joshuabell.xyz" = {
          locations."/" = {
            proxyPass = "http://10.0.0.2:3000";
          };
        };

        # "git.joshuabell.xyz" = {
        #   # GIT passthrough
        #   locations."/" = {
        #     proxyPass = "http://10.0.0.2:3000";
        #   };
        # };

        "_" = {
          default = true;
          locations."/" = {
            return = "404"; # or 444 for drop
          };
        };
      };

      # STREAMS
      streamConfig = ''
        server {
          listen 3032;
          proxy_pass 10.0.0.2:3032;
        }
      '';

    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
