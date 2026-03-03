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
    # beszel-hub binds to overlay IP, needs tailscale interface up
    systemd.services.beszel-hub = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "tailscaled.service" ];
    };

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
