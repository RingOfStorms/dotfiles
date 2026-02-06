{ inputs, pkgs, ... }:
{
  services.nginx.virtualHosts = {
    "puzzles.joshuabell.xyz" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
      locations = {
        "/" = {
          proxyWebsockets = true;
          recommendedProxySettings = true;
          proxyPass = "http://127.0.0.1:8093";
        };
      };
    };
  };
  services.puzzles-server = {
    enable = true;
    package = inputs.puzzles.packages.${pkgs.system}.default;
    settings = {
      http = "127.0.0.1:8093";
    };
  };
}
