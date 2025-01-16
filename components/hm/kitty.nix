{ ... }:
{
  # Enable Kitty terminal
  programs.kitty = {
    enable = true;

    settings = {
      # Window settings
      background_opacity = 1.0;
      os_window_class = "kitty";
      remember_window_size = false;
      placement_strategy = "center";

      # Remove window borders
      # window_decorations = "none";
      hide_window_decorations = "yes";
      dynamic_title = false;

      # Colors (Catppuccin Coal)
      foreground = "#e0e0e0";
      background = "#262626";
      color0 = "#1f1f1f";
      color1 = "#f38ba8";
      color2 = "#a6e3a1";
      color3 = "#f9e2af";
      color4 = "#89b4fa";
      color5 = "#cba6f7";
      color6 = "#89dceb";
      color7 = "#e0e0e0";
      color8 = "#565656";
      color9 = "#f38ba8";
      color10 = "#a6e3a1";
      color11 = "#f9e2af";
      color12 = "#89b4fa";
      color13 = "#cba6f7";
      color14 = "#89dceb";
      color15 = "#ffffff";

      # Font settings
      font_family = "JetBrainsMonoNL Nerd Font";
      font_size = 12.0;
      bold_font = "auto";
      italic_font = "auto";
      italic_bold_font = "auto";
    };

    # If you want to include extra configuration this way instead of through the main `settings` attribute
    extraConfig = ''
      # You can add additional config here if needed
    '';
  };
}
