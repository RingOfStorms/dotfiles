{
  config,
  lib,
  ...
}:
let
  # ccfg = import ../config.nix;
  # cfg_path = "${custom_config_key}".boot.systemd;
  cfg = config.ringofstorms_common.boot.systemd;
in
with lib;
{
  options.ringofstorms_common.boot.systemd = {
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
