{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
with lib;
let
  name = "saber";
  cfg = config.mods.${name};
in
{
  options = {
    mods.${name} = {
      enable = mkEnableOption (lib.mdDoc "Enable ${name}");
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      saber
    ];
  };
}

