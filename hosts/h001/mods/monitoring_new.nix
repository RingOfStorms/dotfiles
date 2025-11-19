{
  inputs,
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
    services.beszel.hub = {
      package = pkgs.beszel;
      enable = true;
      port = 8090;
      host = "100.64.0.13";
      environment = {
        # DISABLE_PASSWORD_AUTH = "true"; # Once sso is setup
      };
    };
  };
}
