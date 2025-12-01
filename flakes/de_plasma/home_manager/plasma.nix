{ osConfig, lib, ... }:
let
  cfg = osConfig.ringofstorms.dePlasma;
  inherit (lib) mkIf;
in
{
  options = {};
  config = mkIf cfg.enable {
    programs.plasma = {
      enable = true;
    };
  };
}
