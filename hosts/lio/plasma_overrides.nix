{ pkgs, lib, config, ... }:
let
  inherit (lib) mkIf;
  cfg = config.ringofstorms.dePlasma;
in
{
  options = {};
  config = mkIf cfg.enable {
    # Example per-host overrides for Plasma on lio
    ringofstorms.dePlasma = {
      monitors = {
        enableOverrides = false; # start disabled for non-overridden machine
        commands = [
          # Example: uncomment and adjust outputs
          # "kscreen-doctor output.DP-1.mode.3840x2160@60 output.DP-1.position.0,0 output.DP-1.primary.true"
          # "kscreen-doctor output.DP-2.mode.3440x1440@99.98 output.DP-2.rotation.left output.DP-2.position.-1440,0"
        ];
        scriptDelayMs = 500;
      };
      sddm.autologinUser = null;
      # GPU vendor left unset; set per machine if needed TODO
    };
  };
}
