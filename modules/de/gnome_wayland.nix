{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  name = "de_gnome_wayland";
  cfg = config.mods.${name};
in
{
  options = {
    mods.${name} = {
      enable = mkEnableOption (lib.mdDoc "Enable GNOME with wayland desktop environment");
    };
  };

  config = mkIf cfg.enable {
    services.xserver = {
      enable = true;
      displayManager.gdm = {
        enable = true;
        autoSuspend = false;
        wayland = true;
      };
      desktopManager.gnome.enable = true;
    };
    services.gnome.core-utilities.enable = false;
    environment.systemPackages = with pkgs; [
      dconf-editor
      # wayland clipboard in terminal
      wl-clipboard
    ];
    environment.sessionVariables.NIXOS_OZONE_WL = "1";
  };
}
