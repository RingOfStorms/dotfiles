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
  xrSetup = ''
    xrandr --output DP-1 --mode 3840x2160 --rate 97.983 --pos 0x0 --primary
    xrandr --output DP-2 --mode 3440x1440 --rate 99.982 --rotate left --left-of DP-1
  '';
  fehCmd = "feh --bg-fill ${bg1} ${bg2}";
  startupCmd = "sh -c 'sleep 0.05; i3-msg workspace number 7; sleep 0.05; i3-msg workspace number 1'";
  i3ExtraOptions = {
    startup = [
      { command = "exec --no-startup-id ${fehCmd}"; }
      { command = "exec --no-startup-id ${xrSetup}"; }
      { command = "exec --no-startup-id ${startupCmd}"; }
    ];
  };
in
{
  options = { };
  config = {
    home-manager.sharedModules = [
      (
        { ... }:
        {
          # xsession.windowManager.i3.config = i3ExtraOptions;
          # xsession.windowManager.i3.extraConfig = assignLines;
        }
      )
    ];
  };
}
