{ config, lib, pkgs, ... }:
let
  cfg = config.ringofstorms.dePlasma;
  inherit (lib) mkIf;
  mkPanel = {
    location ? cfg.panel.location,
    height ? cfg.panel.height,
    opacity ? cfg.panel.opacity,
    widgets ? cfg.panel.widgets
  }: {
    location = location;
    height = height;
    opacity = opacity;
    widgets = widgets;
  };
in
{
  options = {};
  config = mkIf (cfg.enable && cfg.panel.enabled) {
    programs.plasma.panels = [ (mkPanel {}) ];
  };
}
