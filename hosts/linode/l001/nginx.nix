{
  config,
  ...
}:
{

  # JUST A TEST TODO remove
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
    backend = "docker";
    # TODO remove test
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
      # PROXY HOSTS
      "chat.joshuabell.xyz" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://10.20.40.104:3080";
        };
      };
      "gist.joshuabell.xyz" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://10.20.40.190:6157";
        };
      };
      "git.joshuabell.xyz" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://10.20.40.190:6610";
        };
      };
      "nexus.l002.joshuabell.xyz" = {
        locations."/" = {
          proxyPass = "http://localhost:42291";
        };
      };

      # Redirect self IP to domain
      "172.234.26.141" = {
        locations."/" = {
          return = "301 https://joshuabell.xyz";
        };
      };
      "2600:3c06::f03c:95ff:fe2c:2806" = {
        locations."/" = {
          return = "301 https://joshuabell.xyz";
        };
      };

      # NOTE ellalala.com? joshuabell.xyz?

      "_" = {
        default = true;
        locations."/" = {
          return = "404"; # or 444 for drop
        };
      };
    };

    # STREAMS
    # streams = {
    #   # Adding stream configuration for port 3032
    #   "3032" = {
    #     proxyPass = "10.20.40.190:6611";
    #   };
    # };
    streamConfig = ''
      server {
        listen 3032;
        proxy_pass 10.20.40.190:6611;
      }
    '';
  };

  networking.firewall.allowedTCPPorts = [
    80 # web http
    443 # web https
    3032 # git ssh stream
  ];

  networking.firewall.allowedUDPPorts = [
    4242 # nebula
  ];
}

# TODO
# <html>
# <div style="display: flex;width:100vw;height:100vh;justify-content: center;align-items:center;text-align:center;overflow:hidden">
# In the void you roam,</br>
# A page that cannot be found-</br>
# Turn back, seek anew.
# </div>
# </html>
