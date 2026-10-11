{ pkgs, ... }:
{
  services.nginx = {
    enable = true;
    virtualHosts.hello = {
      default = true;
      listen = [ { addr = "0.0.0.0"; port = 8081; } ];
      root = "${pkgs.nginx}/html"; # nginx's own "Welcome to nginx!" page
    };
  };
  system.stateVersion = "25.11";
}
