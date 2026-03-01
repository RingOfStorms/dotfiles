{
  inputs,
  pkgs,
  constants,
  ...
}:
let
  declaration = "services/monitoring/beszel-hub.nix";
  nixpkgsBeszel = inputs.beszel-nixpkgs;
  pkgsBeszel = import nixpkgsBeszel {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  c = constants.services.beszelHub;
  overlayIp = constants.host.overlayIp;
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgsBeszel}/nixos/modules/${declaration}" ];
  config = {
    services.beszel.hub = {
      package = pkgsBeszel.beszel;
      enable = true;
      port = c.port;
      host = overlayIp;
      environment = {
        # DISABLE_PASSWORD_AUTH = "true"; # Once sso is setup
      };
    };
  };
}
