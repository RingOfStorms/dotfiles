{ config, lib, ... }:
{
  options.components.foot = {
    font_size = lib.mkOption {
      type = lib.types.float;
      default = 12.0;
      description = "Font size for Foot terminal";
    };
    alpha = lib.mkOption {
      type = lib.types.float;
      default = 0.935;
      description = "Background opacity for Foot terminal (1.0 = opaque)";
    };
  };
  config = {
    programs.foot = {
      enable = true;

      # This renders to ~/.config/foot/foot.ini
      settings = {
        main = {
          # Use the same font and size as your Kitty config
          font = "JetBrainsMonoNL Nerd Font:size=${toString config.components.kitty.font_size}";

          # Initial window size in character cells (Kitty used 160c x 55c)
          "initial-window-size-chars" = "160x55";
        };

        colors = {
          # Background opacity (1.0 = opaque)
          alpha = toString config.components.foot.alpha;

          # Foreground/background
          foreground = "e0e0e0";
          background = "262626";

          # 16-color palette
          # normal (0–7)
          regular0 = "1f1f1f"; # black
          regular1 = "f38ba8"; # red
          regular2 = "a6e3a1"; # green
          regular3 = "f9e2af"; # yellow
          regular4 = "89b4fa"; # blue
          regular5 = "cba6f7"; # magenta
          regular6 = "89dceb"; # cyan
          regular7 = "e0e0e0"; # white

          # bright (8–15)
          bright0 = "565656"; # bright black
          bright1 = "f38ba8"; # bright red
          bright2 = "a6e3a1"; # bright green
          bright3 = "f9e2af"; # bright yellow
          bright4 = "89b4fa"; # bright blue
          bright5 = "cba6f7"; # bright magenta
          bright6 = "89dceb"; # bright cyan
          bright7 = "ffffff"; # bright white
        };
      };
    };
  };
}
