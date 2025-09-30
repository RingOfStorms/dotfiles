{ lib, pkgs, ... }:
let
  hyprlandExtraOptions = {
    exec-once = [
      # Wait a moment for monitors/workspaces to settle, then "prime" 6 and return to 1
      "sh -lc 'sleep 0.2; hyprctl dispatch workspace 1'"
    ];
    monitor = [
      "eDP-1,2560x1600@165.000Hz,0x0,1.666667,transform,0"
    ];
  };
in
{
  options = { };

  config = {
    ringofstorms_common.desktopEnvironment.hyprland.extraOptions = hyprlandExtraOptions;
    ringofstorms_common.desktopEnvironment.hyprland.hyprpaperSettings = {
      mode = "fill"; # Wallpaper display mode: fill, fit, stretch, center, tile

      preload = [
        "${../_shared_assets/wallpapers/pixel_neon.png}"
      ];

      wallpaper = [
        "eDP-1,${../_shared_assets/wallpapers/pixel_neon.png}"
      ];
    };
  };
}
