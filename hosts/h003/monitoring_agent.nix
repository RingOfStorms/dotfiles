{
  inputs,
  config,
  hostConfig,
  ...
}:
let
  declaration = "services/monitoring/beszel-agent.nix";
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
      environment = {
        SYSTEM_NAME = config.networking.hostName;
        LISTEN = "${hostConfig.overlayIp}:45876";
        HUB_URL = "http://100.64.0.13:8090";
        # TODO this is only safe since I am running it in the overlay network only, rotate all keys if we change that.
        TOKEN = "20208198-87c2-4bd1-ab09-b97c3b9c6a6e";
        KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDcAr8fbW4XyfL/tCMeMtD+Ou/FFywCNfsHdyvYs3qXf";
      };
    };
  };
}
