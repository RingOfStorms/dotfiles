{ ... }:
let
  swayExtraOptions = {
    startup = [
      {
        command = "exec sh -c 'sleep 0.01; swaymsg workspace number 7; sleep 0.02; swaymsg workspace number 1'";
      }
    ];

    # Example: map workspaces 1–6 to DP-1 and 7–10 to HDMI-A-1
    workspaceOutputAssign = [
      {
        workspace = "1";
        output = "DP-1";
      }
      {
        workspace = "2";
        output = "DP-1";
      }
      {
        workspace = "3";
        output = "DP-1";
      }
      {
        workspace = "4";
        output = "DP-1";
      }
      {
        workspace = "5";
        output = "DP-1";
      }
      {
        workspace = "6";
        output = "DP-1";
      }
      {
        workspace = "7";
        output = "DP-2";
      }
      {
        workspace = "8";
        output = "DP-2";
      }
      {
        workspace = "9";
        output = "DP-2";
      }
      {
        workspace = "10";
        output = "DP-2";
      }
    ];

    # Optional output settings
    output = {
      "DP-1" = {
        scale = "1";
        pos = "0 0";
        mode = "3840x2160@97.983Hz";
      };
      "DP-2" = {
        scale = "1";
        transform = "270";
        pos = "-1440 -640";
        mode = "3440x1440@99.982Hz";
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
