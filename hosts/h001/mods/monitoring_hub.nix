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
    # beszel-hub binds to the Tailscale overlay IP. The plain `tailscaled.service`
    # only guarantees the daemon is started, not that the device is logged in and
    # `tailscale0` has its address yet -- so depending on it races and we hit
    # `bind: cannot assign requested address`, the service fails, and (since the
    # upstream unit's RestartSec=30s only triggers on failure once before giving
    # up by default) it stays dead until manually restarted.
    #
    # `tailscaled-autoconnect.service` is `Type=notify` and only finishes when
    # `tailscale up` returns -- i.e. the interface is configured. Depending on it
    # eliminates the race in the normal boot path.
    #
    # IPFreeBind=true is belt-and-suspenders: it lets the process bind to an
    # address that isn't (yet) on any interface, so even a transient flap during
    # start can't fail the bind. See ip(7).
    systemd.services.beszel-hub = {
      wants = [ "network-online.target" "tailscaled-autoconnect.service" ];
      after = [ "network-online.target" "tailscaled-autoconnect.service" ];
      serviceConfig.IPFreeBind = true;
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
