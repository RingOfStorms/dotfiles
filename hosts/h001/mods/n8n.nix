{
  inputs,
  pkgs,
  lib,
  constants,
  ...
}:
let
  declaration = "services/misc/n8n.nix";
  nixpkgsN8n = inputs.n8n-nixpkgs;
  pkgsN8n = import nixpkgsN8n {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  c = constants.services.n8n;
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgsN8n}/nixos/modules/${declaration}" ];
  options = { };
  config = {
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

    services.n8n = {
      enable = true;
    };
    # no package override in this service option
    systemd.services.n8n.serviceConfig.ExecStart = lib.mkForce "${pkgsN8n.n8n}/bin/n8n";
    systemd.services.n8n.environment = {
      # N8N_SECURE_COOKIE = "false";
      N8N_LISTEN_ADDRESS = "127.0.0.1";
      N8N_EDITOR_BASE_URL = "https://${c.domain}/";
      N8N_HOST = c.domain;
      VUE_APP_URL_BASE_API = "https://${c.domain}/";
      N8N_HIRING_BANNER_ENABLED = "false";
      # N8N_PUBLIC_API_DISABLED = "true";
      # N8N_PUBLIC_API_SWAGGERUI_DISABLED = "true";
    };
  };
}
