{ osConfig, lib, pkgs, ... }:
let
  cfg = osConfig.ringofstorms.dePlasma;
  inherit (lib) mkIf;
in
{
  options = {};
  config = mkIf cfg.enable {
    # plasma-manager base enable
    programs.plasma = {
      enable = true;
      # Tweak some global Plasma config if desired later
    };
  };
}
