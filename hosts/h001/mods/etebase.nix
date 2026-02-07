{ ... }:
{
  services.nginx.virtualHosts = {
    "etebase.joshuabell.xyz" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
      locations = {
        "/" = {
          proxyWebsockets = true;
          recommendedProxySettings = true;
          proxyPass = "http://127.0.0.1:8732";
        };
      };
    };
  };

  services.etebase-server = {
    enable = true;
    port = 8732;
    settings = {
      global = {
        debug = false;
      };
      allowed_hosts = {
        allowed_host1 = "etebase.joshuabell.xyz";
      };
    };
  };
}
