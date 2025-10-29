{
  pkgs,
  ...
}:
{
  programs.rofi = {
    enable = true;
    plugins = with pkgs; [ rofi-calc ];
    extraConfig = {
      modi = "drun,run,ssh,window,calc";
      terminal = "alacritty";
    };
    theme = "Arc-Dark";
  };
  programs.wofi = {
    enable = true;
  };
}
