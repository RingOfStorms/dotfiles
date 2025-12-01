{ ... }:
let
  workspaces = builtins.genList (i: i + 1) 9;
  kwinWorkspace = builtins.listToAttrs (
    map (i: {
      name = "Switch to Desktop ${toString i}";
      value = "Meta+${toString i}";
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
  config = {
    programs.plasma.shortcuts = ({
      kwin = ({ "Close Window" = "Meta+Q"; } // kwinWorkspace // kwinMoveWorkspace);
      krunner = {
        "Run Command" = "Meta+Space";
      };
    });

    programs.plasma.hotkeys.commands = {
      ringofstorms-terminal = {
        key = "Meta+Return";
        command = "foot"; # TODO configurable?
      };
    };
  };
}
