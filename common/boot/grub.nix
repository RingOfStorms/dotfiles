{
  config,
  lib,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "boot"
    "grub"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "Grub bootloader";
      device = lib.mkOption {
        type = lib.types.str;
        default = "/dev/sda";
        description = ''
          The device to install GRUB on.
        '';
      };
    };

  config = lib.mkIf cfg.enable {
    boot.loader.grub = {
      enable = true;
      device = cfg.device;
    };
  };
}
