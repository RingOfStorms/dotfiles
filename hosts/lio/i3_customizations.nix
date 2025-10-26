{ pkgs, ... }:
let
  assignLines = ''
    workspace 1 output DP-1
    workspace 2 output DP-1
    workspace 3 output DP-1
    workspace 4 output DP-1
    workspace 5 output DP-1
    workspace 6 output DP-1
    workspace 7 output DP-2
    workspace 8 output DP-2
    workspace 9 output DP-2
    workspace 10 output DP-2
  '';
  bg1 = ../_shared_assets/wallpapers/pixel_neon.png;
  bg2 = ../_shared_assets/wallpapers/pixel_neon_v.png;
  xrSetup = "xrandr --output DP-1 --mode 3840x2160 --rate 97.983 --pos 0x0 --primary; xrandr --output DP-2 --mode 3440x1440 --rate 99.982 --rotate left --left-of DP-1";
  xwallpaperCmd = "xwallpaper --output DP-1 --zoom ${bg1} --output DP-2 --zoom ${bg2}";
  startupCmd = "sh -c 'sleep 0.2; i3-msg workspace number 7; sleep 0.2; i3-msg workspace number 1'";
  i3ExtraOptions = {
    startup = [
      { command = "${xrSetup}"; }
      { command = "sh -c 'sleep 0.5; ${xwallpaperCmd}'"; }
      { command = "${startupCmd}"; }
    ];
  };
in
{
  options = { };
  config = {
    home-manager.sharedModules = [
      (
         { lib, pkgs, ... }:
         let
           inherit (lib) mkAfter;
         in
         {
           xsession.windowManager.i3.config.startup = mkAfter i3ExtraOptions.startup;
           xsession.windowManager.i3.extraConfig = mkAfter assignLines;
            home.packages = [ pkgs.xwallpaper pkgs.xorg.xrandr ];
         }
      )
    ];
  };
}
