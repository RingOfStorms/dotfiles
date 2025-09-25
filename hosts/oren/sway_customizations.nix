{ ... }:
let
  swayExtraOptions = {
    startup = [
      {
        command = "exec sh -c 'sleep 0.01; swaymsg workspace number 1'";
      }
    ];

    # Optional output settings
    output = {
      "eDP-1" = {
        scale = "1";
        pos = "0 0";
        mode = "2560x1600@165.000Hz";
        bg = "${../_shared_assets/wallpapers/pixel_neon.png} fill";
      };
    };
  };

in
{
  options = { };

  config = {
    environment.systemPackages = [ ];

    ringofstorms_common.desktopEnvironment.sway.extraOptions = swayExtraOptions;
  };
}
