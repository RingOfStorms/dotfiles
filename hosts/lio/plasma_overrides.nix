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
      diskMonitor.sensors = [
        { name = "disk/NIXROOT/usedPercent"; color = "180,190,254"; label = "/"; }
        { name = "disk/NIXBOOT/usedPercent"; color = "166,227,161"; label = "/boot"; }
        # Uses UUID since fstab mounts by-uuid
        { name = "disk/7ddb48bd-160c-4049-a4fa-a5ac2b6a5402/usedPercent"; color = "249,226,175"; label = "/mnt/nvme1tb"; }
      ];
      sddm.autologinUser = null;
      # GPU vendor left unset; set per machine if needed TODO
    };
  };
}
