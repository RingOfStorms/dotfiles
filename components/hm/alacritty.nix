{ ... }:
{
  # More of an experiment to try out since wezterm is being weird on wayland...
  programs.alacritty = {
    enable = true;
    settings = {
      window = {
        # TODO revisit, I still want some border shadow but no top bar but that is not an option
        decorations = "None";
        dynamic_title = false;
      };
      colors = {
        primary = {
          foreground = "#e0e0e0";
          background = "#262626";
        };
        normal = {
          # Catppuccin Coal
          black = "#1f1f1f";
          red = "#f38ba8";
          green = "#a6e3a1";
          yellow = "#f9e2af";
          blue = "#89b4fa";
          magenta = "#cba6f7";
          cyan = "#89dceb";
          white = "#e0e0e0";
        };
      };
      font = {
        normal = { family = "JetBrainsMonoNL Nerd Font"; style = "Regular"; };
        size = 12.0;
        ## TODO use 16 on macos ...
      };
      # TODO revisit... none of this is working.
      # NOTE: I probably wont need these anymore, I've since entirely remade and relearned my tmux shortcuts to not be based on these
      keyboard.bindings = [
        # { key = "m"; mods = "Command"; chars = "test"; }
        # { key = "t"; mods = "Control"; action = { SendString = "\\x01t"; }; }
        # { key = "w"; mods = "Control"; action = { SendString = "\\x01w"; }; }
        # { key = "o"; mods = "Control"; action = { SendString = "testing123"; }; }
        # { key = "w"; mods = "Control"; chars = "\\\\x01w"; }
        # { key = "o"; mods = "Control"; chars = "\\\\x01o"; }
        # { key = "1"; mods = "Control"; chars = "\\\\x011"; }
        # { key = "2"; mods = "Control"; chars = "\\\\x012"; }
      ];
    };
  };
}

