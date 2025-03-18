{ ... }:
{
  programs.alacritty = {
    enable = true;
    settings = {
      window = {
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
      };
    };
  };
}

