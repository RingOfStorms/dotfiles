{
  pkgs,
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

  security.acme.acceptTerms = true;
  security.acme.defaults.email = "admin@joshuabell.xyz";
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    virtualHosts = {
      # default that is put first for fallbacks
      # Note that order here doesn't matter it orders alphabetically so `0` puts it first
      # I had an issue tha the first SSL port 443 site would catch any https traffic instead
      # of hitting my default fallback and this fixes that issue and ensure this is hit instead
      "002.linodes.joshuabell.xyz" = {
        default = true;
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          return = "444"; # 404 for not found or 444 for drop
        };
      };
      # PROXY HOSTS
      "chat.joshuabell.xyz" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyWebsockets = true;
          proxyPass = "http://100.64.0.1:3080";
        };
      };
      "db.joshuabell.xyz" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyWebsockets = true;
          proxyPass = "http://100.64.0.1:3085";
        };
      };
      "gist.joshuabell.xyz" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://100.64.0.2:6157";
        };
      };
      "git.joshuabell.xyz" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://100.64.0.2:6610";
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

      "www.joshuabell.xyz" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          return = "301 https://joshuabell.xyz";
        };
      };
      "joshuabell.xyz" = {
        enableACME = true;
        forceSSL = true;
        locations = {
          "/wasabi" = {
            proxyPass = "http://192.168.100.11/";
            extraConfig = ''
              rewrite ^/wasabi/(.*) /$1 break;
            '';
          };
          "/" = {
            # return = "200 '<html>Hello World</html>'";
            extraConfig = ''
              default_type text/html;
              return 200 '
                <html>
                  <body style="width:100vw;height:100vh;overflow:hidden">
                    <div style="display: flex;width:100vw;height:100vh;justify-content: center;align-items:center;text-align:center;overflow:hidden">
                      In the void you roam,</br>
                      A page that cannot be found-</br>
                      Turn back, seek anew.
                    </div>
                  </body>
                </html>
              ';
            '';
          };
        };
      };

      "www.ellalala.com" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          return = "301 https://ellalala.com";
        };
      };
      "ellalala.com" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          return = "444";
        };
      };
    };

    # STREAMS
    # TODO left off trying to get direct ssh working...
    streamConfig = ''
      server {
        listen 3032;
        proxy_pass 100.64.0.2:6611;
      }
    '';
  };

  # Convoluted way to get ssh to work for git server while also still allowing
  # ssh connections to the machine normally (you can't have nginx bind port 22 since sshd does)
  # but sshd allows us to use a ForceCommand that we cna then proxy through
  environment.systemPackages = with pkgs; [
    # NOTE requires nc which I am getting from somewhere.... would be better to put it here in sys packs?
    (writeScriptBin "proxy-to-git" ''
      #!${pkgs.bash}/bin/bash
      nc 100.64.0.2 6611
    '')
  ];

# TODO havent gotten this fully working yet

  services.openssh.extraConfig = ''
    Match Host git.joshuabell.xyz
      ForceCommand proxy-to-git
      PermitTTY no
      X11Forwarding no
      PermitTunnel no
      GatewayPorts no
      AllowAgentForwarding no
  '';

  networking.firewall.allowedTCPPorts = [
    80 # web http
    443 # web https
    3032 # git ssh stream
  ];

  networking.firewall.allowedUDPPorts = [
    4242 # nebula
  ];
}
