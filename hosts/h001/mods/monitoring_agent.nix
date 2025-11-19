{
  inputs,
  config,
  ...
}:
let
  declaration = "services/monitoring/beszel-hub.nix";
  nixpkgs = inputs.beszel-nixpkgs;
  pkgs = import nixpkgs {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgs}/nixos/modules/${declaration}" ];
  config = {
    services.beszel.agent = {
      package = pkgs.beszel;
      enable = true;
      host = "100.64.0.13";
      environment = {
        LISTEN = "100.64.0.13:45876";
        SYSTEM_NAME = config.networking.hostName;
        TOKEN = "20208198-87c2-4bd1-ab09-b97c3b9c6a6e";
        HUB_URL = "http://100.64.0.13:8090";
      };
    };
  };
}
