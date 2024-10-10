{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
with lib;
let
  name = "tty_caps_esc";
  cfg = config.mods.${name};
in
{
  options = {
    mods.${name} = {
      enable = mkEnableOption (lib.mdDoc "Enable ${name}");
    };
  };

  config = mkIf cfg.enable {
    services.xserver.xkb.options = "caps:escape";
    console = {
      earlySetup = true;
      packages = with pkgs; [ terminus_font ];
      useXkbConfig = true; # use xkb.options in tty. (caps -> escape)
    };
  };
}
