{ inputs, pkgs, constants, fleet, lib, ... }:
let
  c = constants.services.puzzles;
in
{
  nixpkgs.config = {
    allowUnfreePredicate = pkg:
      builtins.elem (lib.getName pkg) [ "puzzles" ];
    permittedInsecurePackages = [ "pnpm-9.15.9" ];
  };

  services.nginx.virtualHosts = {
    "${c.domain}" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/${fleet.global.domain}/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/${fleet.global.domain}/key.pem";
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
    # Build with this host's configured nixpkgs so its unfree predicate applies.
    package = pkgs.callPackage "${inputs.puzzles}/nix/package.nix" { };
    settings = {
      http = "127.0.0.1:${toString c.port}";
    };
  };
}
