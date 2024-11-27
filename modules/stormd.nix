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
      debug = mkOption {
        type = types.bool;
        default = false;
        description = lib.mdDoc "Whether to enable debug logging for stormd daemon.";
      };
    };
  };

  imports = [ ringofstorms-stormd.nixosModules.${settings.system.system} ];

  config = mkIf cfg.enable {
    services.stormd = {
      enable = true;
      nebulaPackage = pkgs.nebula;
      extraOptions = mkIf cfg.debug [ "-v" ];
    };
  };
}
