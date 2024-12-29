{
  config,
  lib,
  ...
}:
with lib;
let
  cfg = config.mods.common;
in
{
  config = mkIf cfg.zsh {
    programs.zsh.enable = true;
    environment.pathsToLink = [ "/share/zsh" ];
  };
}
