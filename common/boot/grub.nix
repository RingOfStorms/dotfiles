{ config, lib, ... }:
with lib;
{
  options.mods.boot_grub = {
    device = mkOption {
      type = types.str;
      default = "/dev/sda";
      description = ''
        The device to install GRUB on.
      '';
    };
  };
  config = {
    boot.loader.grub = {
      enable = true;
      device = config.mods.boot_grub.device;
    };
  };
}
