{
  pkgs,
  lib,
  nixConfig,
  ...
}:
{
  home.packages = lib.mkIf (!nixConfig.mods.de_cosmic.enable) (with pkgs; [ nautilus qimgv ]);
}
