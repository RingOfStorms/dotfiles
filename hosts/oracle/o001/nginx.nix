{
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
    virtualHosts =
      let
        tailnetConfig = {
          locations = {
            "/" = {
              extraConfig = ''
                default_type text/html;
                return 200 '
                  <html>
                    jRmvVcy0mlTrVJGiPMHsiCF6pQ2JCDNe2LiYJwcwgm8=
                  </html>
                ';
              '';
            };
          };

        };
      in
      {
        # Redirect self IP to domain
        "64.181.210.7" = {
          locations."/" = {
            return = "301 https://joshuabell.xyz";
          };
        };

        "100.64.0.11" = tailnetConfig;
        "o001.net.joshuabell.xyz" = tailnetConfig;

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

        # PROXY HOSTS
        "chat.joshuabell.xyz" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://100.64.0.1:3080";
          };
        };
        "gist.joshuabell.xyz" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://100.64.0.13";
          };
        };
        "git.joshuabell.xyz" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://100.64.0.13";
          };
        };
        "obsidiansync.joshuabell.xyz" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://100.64.0.1:5984";
          };
          extraConfig = ''
            client_max_body_size 100M;
            proxy_redirect off;
            proxy_buffering off;
            proxy_set_header Host $host;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          '';
        };

        "_" = {
          default = true;
          locations."/" = {
            return = "444"; # 404 for not found or 444 for drop
          };
        };
      };

    # STREAMS
    streamConfig = ''
      server {
        listen 3032;
        proxy_pass 100.64.0.13:3032;
      }
    '';
  };

  # NOTE Oracle also has security rules that must expose these ports so this alone will not work! See readme
  networking.firewall.allowedTCPPorts = [
    80 # web http
    443 # web https

    3032 # ssh for git server
  ];
}
