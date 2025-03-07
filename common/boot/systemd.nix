{
  custom_config_key,
  config,
  lib,
  ...
}:
let
  cfg_path = "${custom_config_key}".boot.systemd;
  cfg = config.${cfg_path};
in
with lib;
{
  options.${cfg_path} = {
    enable = mkEnableOption "Systemd bootloader";
  };
  config = mkIf cfg.enable {
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
