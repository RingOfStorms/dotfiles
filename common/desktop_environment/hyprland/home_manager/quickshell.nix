{
  osConfig,
  lib,
  pkgs,
  ...
}:
let
  ccfg = import ../../../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "desktopEnvironment"
    "hyprland"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path osConfig;
in
{
  home.packages = with pkgs; [
    quickshell

    pulseaudio
    brightnessctl
    networkmanager
    bluez
    bluez-tools
    power-profiles-daemon
    upower
    systemd
    hyprlock
  ];
}
