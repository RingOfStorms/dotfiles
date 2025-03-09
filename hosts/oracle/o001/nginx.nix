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
    virtualHosts = {
      # Redirect self IP to domain
      "64.181.210.7" = {
        locations."/" = {
          return = "301 https://o001.joshuabell.xyz";
        };
      };

      "o001.joshuabell.xyz" = {
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

      "_" = {
        default = true;
        locations."/" = {
          return = "404"; # 404 for not found or 444 for drop
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    80 # web http
    443 # web https
  ];
}
