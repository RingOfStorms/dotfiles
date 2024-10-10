{
  config,
  lib,
  ...
}:
with lib;
let
  name = "boot_grub";
  cfg = config.mods.${name};
in
{
  options = {
    mods.${name} = {
      enable = mkEnableOption (lib.mdDoc "Enable ${name}");
      device = mkDefaultOption {
        type = types.str;
        default = "/dev/sda";
        description = ''
          The device to install GRUB on.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    boot.loader.grub = {
      enable = true;
      device = cfg.device;
    };
  };
}
