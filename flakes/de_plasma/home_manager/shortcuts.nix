{ osConfig, lib, ... }:
let
  cfg = osConfig.ringofstorms.dePlasma;
  inherit (lib) mkIf;
  workspaces = builtins.genList (i: i + 1) 9;
  workspaceLetters = [
    "n"
    "m"
    "Comma"
    "Period"
    "Slash"
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
      value =
        let
          idx = i - 1;
        in
        if idx < builtins.length workspaceLetters then
          [
            "Meta+Shift+${toString i}"
            "Meta+Shift+${builtins.elemAt workspaceLetters idx}"
          ]
        else
          "Meta+Shift+${toString i}";
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

        # Vim-style focus move
        "Switch Window Left" = "Meta+H";
        "Switch Window Down" = "Meta+J";
        "Switch Window Up" = "Meta+K";
        "Switch Window Right" = "Meta+L";

        # Vim-style snap/maximize/restore
        "Window Quick Tile Left" = "Meta+Shift+H";
        "Window Quick Tile Right" = "Meta+Shift+L";

        # No dedicated "unsnap" action; this reliably breaks quick-tiling.
        "Window Move Center" = "Meta+Shift+J";

        "Window Maximize" = "Meta+Shift+K";

        "Window On All Desktops" = "Meta+P";
      }
      // kwinWorkspace
      // kwinMoveWorkspace;

      "org.kde.kscreen.desktop" = {
        # Unbind default (Display / Meta+P) so Meta+P can be used by KWin.
        "ShowOSD" = "none";
      };

      plasmashell = {
        "activate application launcher widget" = [ ];
      };

      ksmserver = {
        "Lock Session" = "none";
      };

      # "KDE Keyboard Layout Switcher"."Switch to Next Keyboard Layout" = "Meta+K";
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
