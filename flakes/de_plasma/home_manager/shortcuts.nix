{ osConfig, lib, ... }:
let
  cfg = osConfig.ringofstorms.dePlasma;
  inherit (lib) mkIf;
  workspaces = builtins.genList (i: i + 1) 9;
  workspaceLetters = [
    "n"
    "m"
    ","
    "."
    "/"
  ];
  kwinWorkspace = builtins.listToAttrs (
    map (i: {
      name = "Switch to Desktop ${toString i}";
      value =
        let
          idx = i - 1;
        in
        if idx < builtins.length workspaceLetters then
          [
            "Meta+${toString i}"
            "Meta+${builtins.elemAt workspaceLetters idx}"
          ]
        else
          "Meta+${toString i}";
    }) workspaces
  );
  kwinMoveWorkspace = builtins.listToAttrs (
    map (i: {
      name = "Window to Desktop ${toString i}";
      value = "Meta+Shift+${toString i}";
    }) workspaces
  );
in
{
  options = { };
  config = mkIf (cfg.enable) {
    # Configure virtual desktops declaratively
    programs.plasma.shortcuts = {
      kwin = {
        "Window Close" = "Meta+Q";
        "Overview" = "Meta";
      }
      // kwinWorkspace
      // kwinMoveWorkspace;

      plasmashell = {
        "activate application launcher widget" = [ ];
      };

      ksmserver = {
        "Lock Session" = "Meta+Shift+L";
      };

      "KDE Keyboard Layout Switcher"."Switch to Next Keyboard Layout" = "Meta+K";
    };

    # Custom hotkey commands
    programs.plasma.hotkeys.commands = {
      terminal = {
        key = "Meta+Return";
        command = "kitty";
      };
    };
  };
}
