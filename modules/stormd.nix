{
  config,
  lib,
  pkgs,
  ringofstorms-stormd,
  settings,
  ...
}:
with lib;
let
  name = "stormd";
  cfg = config.mods.${name};
in
{
  options = {
    mods.${name} = {
      enable = mkEnableOption (lib.mdDoc "Enable ${name}");
    };
  };

  imports = [ ringofstorms-stormd.nixosModules.${settings.system.system} ];

  config = mkIf cfg.enable {
    services.stormd = {
      enable = true;
      nebulaPackage = pkgs.nebula;
      extraOptions = [ "-v" ];
    };
  };
}
