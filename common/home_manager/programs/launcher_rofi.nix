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
    theme = "glue_pro_blue";
  };
  programs.wofi = {
    enable = true;
  };
}
