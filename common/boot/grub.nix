{
  config,
  lib,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg = config.${ccfg.custom_config_key}.boot.grub;
in
with lib;
{
  options.${ccfg.custom_config_key}.boot.grub = {
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
