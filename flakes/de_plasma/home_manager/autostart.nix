{
  osConfig,
  lib,
  pkgs,
  ...
}:
let
  cfg = osConfig.ringofstorms.dePlasma;
  inherit (lib) mkIf;
  delayMs = cfg.monitors.scriptDelayMs;
  script = pkgs.writeShellScriptBin "plasma-kscreen-overrides" ''
    set -euo pipefail
    sleep $((${toString delayMs} / 1000)).$(( ${toString delayMs} % 1000 ))
    ${lib.concatStringsSep "\n" (map (c: c) cfg.monitors.commands)}
  '';
in
{
  options = { };
  config = mkIf (cfg.enable && cfg.monitors.enableOverrides && cfg.monitors.commands != [ ]) {
    # Use XDG autostart
    # xdg.autostart."ringofstorms-kscreen-overrides" = {
    #   name = "Apply monitor overrides";
    #   exec = "${script}/bin/plasma-kscreen-overrides";
    # };
  };
}
