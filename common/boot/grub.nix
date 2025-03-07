{
  custom_config_key,
  config,
  lib,
  ...
}:
let
  cfg = config."${custom_config_key}".boot.grub;
in
with lib;
{
  options."${custom_config_key}".boot.grub = {
    enable = mkEnableOption "Grub bootloader";
    device = mkOption {
      type = types.str;
      default = "/dev/sda";
      description = ''
        The device to install GRUB on.
      '';
    };
  };
  config = mkIf cfg.enable {
    boot.loader.grub = {
      enable = true;
      device = cfg.device;
    };
  };
}
