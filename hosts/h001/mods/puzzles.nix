{ inputs, pkgs, constants, ... }:
let
  c = constants.services.puzzles;
in
{
  services.nginx.virtualHosts = {
    "${c.domain}" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
      locations = {
        "/" = {
          proxyWebsockets = true;
          recommendedProxySettings = true;
          proxyPass = "http://127.0.0.1:${toString c.port}";
        };
      };
    };
  };
  services.puzzles-server = {
    enable = true;
    package = inputs.puzzles.packages.${pkgs.stdenv.hostPlatform.system}.default;
    settings = {
      http = "127.0.0.1:${toString c.port}";
    };
  };
}
