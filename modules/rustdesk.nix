{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  name = "rustdesk";
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
      rustdesk
    ];
  };
}
