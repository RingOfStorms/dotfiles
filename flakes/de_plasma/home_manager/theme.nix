{ config, lib, pkgs, ... }:
let
  cfg = config.ringofstorms.dePlasma;
  inherit (lib) mkIf;
in
{
  options = {};
  config = mkIf (cfg.enable && cfg.appearance.dark.enable) {
    programs.plasma = {
      workspace = {
        colorScheme = "Breeze Dark";
        lookAndFeel = "org.kde.breezedark.desktop";
        cursorTheme = "breeze_cursors";
      };
      fonts = { }; # keep defaults
      kscreenlocker = { }; # swaylock analog not applicable; left default
    };
  };
}
