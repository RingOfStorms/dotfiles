{
  config,
  lib,
  ...
}:
with lib;
let
  name = "boot_systemd";
  cfg = config.mods.${name};
in
{
  options = {
    mods.${name} = {
      enable = mkEnableOption (lib.mdDoc "Enable ${name}");
    };
  };

  config = mkIf cfg.enable {
    # Use the systemd-boot EFI boot loader.
    boot.loader = {
      systemd-boot = {
        enable = true;
        consoleMode = "keep";
      };
      timeout = 5;
      efi = {
        canTouchEfiVariables = true;
      };
    };
  };
}
