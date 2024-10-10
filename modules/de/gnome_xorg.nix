{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  name = "de_gnome_xorg";
  cfg = config.mods.${name};
in
{
  options = {
    mods.${name} = {
      enable = mkEnableOption "Enable GNOME with wayland desktop environment";
    };
  };

  config = mkIf cfg.enable {
    services.xserver = {
      enable = true;
      displayManager.gdm = {
        enable = true;
        autoSuspend = false;
        wayland = false;
      };
      desktopManager.gnome.enable = true;
    };
    services.gnome.core-utilities.enable = false;
    environment.systemPackages = with pkgs; [
      gnome.dconf-editor
      xclip
    ];
  };
}
