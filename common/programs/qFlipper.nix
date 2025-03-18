{
  config,
  lib,
  pkgs,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "programs"
    "qFlipper"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "qFlipper";
    };

  config = lib.mkIf cfg.enable {
    hardware.flipperzero.enable = true;
    environment.systemPackages = with pkgs; [ qFlipper ];
    services.udev.extraRules = ''
      #Flipper Zero serial port
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="5740", ATTRS{manufacturer}=="Flipper Devices Inc.", GROUP="users", TAG+="uaccess"
      #Flipper Zero DFU
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="df11", ATTRS{manufacturer}=="STMicroelectronics", GROUP="users", TAG+="uaccess"
    '';
  };
}
