{
  inputs,
  pkgs,
  ...
}:
let
  declaration = "services/monitoring/beszel-hub.nix";
  nixpkgsBeszel = inputs.beszel-nixpkgs;
  pkgsBeszel = import nixpkgsBeszel {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgsBeszel}/nixos/modules/${declaration}" ];
  config = {
    services.beszel.hub = {
      package = pkgsBeszel.beszel;
      enable = true;
      port = 8090;
      host = "100.64.0.13";
      environment = {
        # DISABLE_PASSWORD_AUTH = "true"; # Once sso is setup
      };
    };
  };
}
