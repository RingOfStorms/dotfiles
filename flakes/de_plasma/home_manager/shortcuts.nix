{ config, lib, pkgs, ... }:
let
  cfg = config.ringofstorms.dePlasma;
  inherit (lib) mkIf;
  workspaces = builtins.genList (i: i + 1) 9;
  kwinWorkspace = builtins.listToAttrs (map (i: {
    name = "Switch to Desktop ${toString i}";
    value = "Meta+${toString i}";
  }) workspaces);
  kwinMoveWorkspace = builtins.listToAttrs (map (i: {
    name = "Window to Desktop ${toString i}";
    value = "Meta+Shift+${toString i}";
  }) workspaces);
  krunnerShortcut = if cfg.shortcuts.launcher == "krunner" then {
    krunner = { "Run Command" = "Meta+Space"; };
  } else { };
in
{
  options = {};
  config = mkIf (cfg.enable && cfg.shortcuts.useI3Like) {
    programs.plasma.shortcuts =
      ({
        kwin = ({ "Close Window" = cfg.shortcuts.closeWindow; } // kwinWorkspace // kwinMoveWorkspace);
      } // krunnerShortcut);

    programs.plasma.hotkeys.commands = {
      ringofstorms_terminal = {
        key = "Meta+Return";
        command = cfg.shortcuts.terminal;
      };
    } // (if cfg.shortcuts.launcher == "rofi" then {
      ringofstorms_launcher = {
        key = "Meta+Space";
        command = "rofi -show drun";
      };
    } else {});
  };
}
