{
  osConfig,
  lib,
  ...
}:
let
  cfg = osConfig.ringofstorms.dePlasma;
  inherit (lib) mkIf;
in
{
  options = { };
  config = mkIf (cfg.enable && cfg.appearance.dark.enable) {
    programs.plasma = {
      workspace = {
        colorScheme = "Breeze Dark";
        lookAndFeel = "org.kde.breezedark.desktop";
        cursor.theme = "breeze_cursors";
      };
      fonts = { }; # keep defaults
      kscreenlocker = { }; # swaylock analog not applicable; left default
    };
  };
}
