{
  pkgs,
  nixConfig,
  lib,
  ...
}:
{
  programs.rofi = lib.mkIf nixConfig.mods.de_gnome_xorg.enable {
    enable = true;
    plugins = with pkgs; [ rofi-calc ];
    extraConfig = {
      modi = "drun,run,ssh,window,calc";
      terminal = "alacritty";
    };
    theme = "glue_pro_blue";
  };
  programs.wofi = lib.mkIf nixConfig.mods.de_gnome_wayland.enable {
    enable = true;
  };
}
