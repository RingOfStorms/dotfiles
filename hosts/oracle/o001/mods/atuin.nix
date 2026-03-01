{
  config,
  constants,
  ...
}:
let
  atuin = constants.services.atuin;
in
{
  services.atuin = {
    enable = true;
    openRegistration = false;
    openFirewall = false;
    host = "127.0.0.1";
    port = atuin.port;
  };

  services.nginx.virtualHosts."${atuin.domain}" = {
    enableACME = true;
    forceSSL = true;
    locations = {
      "/" = {
        proxyWebsockets = true;
        proxyPass = "http://127.0.0.1:${builtins.toString config.services.atuin.port}";
      };
    };
  };
}
