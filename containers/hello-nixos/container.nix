{ pkgs, ... }:
{
  services.nginx = {
    enable = true;
    virtualHosts.hello = {
      default = true;
      listen = [
        {
          addr = "127.0.0.1"; # loopback only; the host nginx fronts it (routes.web)
          port = 8081;
        }
      ];
      root = "${pkgs.nginx}/html"; # nginx's own "Welcome to nginx!" page
    };
  };
  system.stateVersion = "25.11";
}
