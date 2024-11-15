{
  config,
  lib,
  settings,
  ringofstorms-nvim,
  ...
}:
with lib;
let
  name = "neovim";
  cfg = config.mods.${name};
in
{
  options = {
    mods.${name} = {
      enable = mkEnableOption (lib.mdDoc "Enable ${name}");
    };
  };

  config = mkIf cfg.enable {
    environment = {
      systemPackages = [
        ringofstorms-nvim.packages.${settings.system.system}.neovim
      ];
    };
  };
}
