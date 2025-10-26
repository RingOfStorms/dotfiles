{ pkgs, ... }:
{
  xsession.enable = true;
  xsession.windowManager.i3 = {
    enable = true;
    package = pkgs.i3;
    extraConfig = ''
        focus_follows_mouse no
        default_border pixel 1
        default_floating_border pixel 1
        floating_modifier Mod4
    '';
    config = rec {
      modifier = "Mod4";
      terminal = "kitty";
      menu = "rofi -show drun";


      focus.followMouse = false;

      gaps = {
        inner = 2;
        outer = 5;
        smartBorders = "on";
      };

      keybindings = {
        "${modifier}+return" = "exec ${terminal}";
        "${modifier}+space" = "exec pkill rofi || rofi -show drun";
        "${modifier}+q" = "kill";
        "${modifier}+shift+Escape" = "exit";
        "${modifier}+shift+q" = "exec i3lock";
        "${modifier}+f" = "floating toggle";

        "${modifier}+h" = "focus left";
        "${modifier}+l" = "focus right";
        "${modifier}+k" = "focus up";
        "${modifier}+j" = "focus down";

        "${modifier}+1" = "workspace number 1";
        "${modifier}+n" = "workspace number 1";
        "${modifier}+2" = "workspace number 2";
        "${modifier}+m" = "workspace number 2";
        "${modifier}+3" = "workspace number 3";
        "${modifier}+comma" = "workspace number 3";
        "${modifier}+4" = "workspace number 4";
        "${modifier}+period" = "workspace number 4";
        "${modifier}+5" = "workspace number 5";
        "${modifier}+slash" = "workspace number 5";
        "${modifier}+6" = "workspace number 6";
        "${modifier}+7" = "workspace number 7";
        "${modifier}+8" = "workspace number 8";
        "${modifier}+9" = "workspace number 9";
        "${modifier}+0" = "workspace number 10";

        "${modifier}+shift+h" = "move left";
        "${modifier}+shift+l" = "move right";
        "${modifier}+shift+k" = "move up";
        "${modifier}+shift+j" = "move down";
        "${modifier}+shift+1" = "move container to workspace number 1";
        "${modifier}+shift+n" = "move container to workspace number 1";
        "${modifier}+shift+2" = "move container to workspace number 2";
        "${modifier}+shift+m" = "move container to workspace number 2";
        "${modifier}+shift+3" = "move container to workspace number 3";
        "${modifier}+shift+comma" = "move container to workspace number 3";
        "${modifier}+shift+4" = "move container to workspace number 4";
        "${modifier}+shift+period" = "move container to workspace number 4";
        "${modifier}+shift+5" = "move container to workspace number 5";
        "${modifier}+shift+slash" = "move container to workspace number 5";
        "${modifier}+shift+6" = "move container to workspace number 6";
        "${modifier}+shift+7" = "move container to workspace number 7";
        "${modifier}+shift+8" = "move container to workspace number 8";
        "${modifier}+shift+9" = "move container to workspace number 9";
        "${modifier}+shift+0" = "move container to workspace number 10";

        "${modifier}+left" = "resize shrink width 10 px or 10 ppt";
        "${modifier}+down" = "resize shrink height 10 px or 10 ppt";
        "${modifier}+up" = "resize grow height 10 px or 10 ppt";
        "${modifier}+right" = "resize grow width 10 px or 10 ppt";

        "Print" = "exec sh -c 'maim -s | xclip -selection clipboard -t image/png'";
      };

      bars = [
        {
          position = "top";
          statusCommand = "${pkgs.i3status}/bin/i3status";
        }
      ];

      startup = [ ];
    };
  };
}
