{
  osConfig,
  lib,
  ...
}:
let
  cfg = osConfig.ringofstorms.dePlasma;
  inherit (lib) mkIf mkDefault;

  defaultPanel = {
    location = "top";
    height = 24;
    opacity = "translucent"; # "adaptive" | "translucent" | "opaque"
    floating = true;
    hiding = "dodgewindows";
    lengthMode = "fill";
    widgets = [
      "org.kde.plasma.kickoff"
      "org.kde.plasma.pager"
      "org.kde.plasma.icontasks"
      #
      "org.kde.plasma.marginsseparator"
      #
      "org.kde.plasma.systemtray"
      "org.kde.plasma.networkmanagement"
      "org.kde.plasma.bluetooth"
      "org.kde.plasma.volume"
      "org.kde.plasma.battery"
      # "org.kde.plasma.powerprofiles"
      "org.kde.plasma.notifications"
      "org.kde.plasma.digitalclock"
      "org.kde.plasma.showdesktop"
    ];
  };
in
{
  options = { };
  config = mkIf cfg.enable {
    programs.plasma.panels = mkDefault [ defaultPanel ];
  };
}
