{
  config,
  ...
}:
{
  services.atuin = {
    enable = true;
    openRegistration = false;
    openFirewall = false;
    host = "127.0.0.1";
    port = 8888;
  };

  services.nginx.virtualHosts."atuin.joshuabell.xyz" = {
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
