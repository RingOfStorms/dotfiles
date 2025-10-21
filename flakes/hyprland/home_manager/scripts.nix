{ pkgs, ... }:
{
  home.packages = with pkgs; [
    (writeShellScriptBin "toggle-airplane-mode" (builtins.readFile ./scripts/toggle-airplane-mode.sh))
    (writeShellScriptBin "toggle-power-profile" (builtins.readFile ./scripts/toggle-power-profile.sh))
    (writeShellScriptBin "wofi-wifi-menu" (builtins.readFile ./scripts/wofi-wifi-menu.sh))
    (writeShellScriptBin "wofi-bluetooth-menu" (builtins.readFile ./scripts/wofi-bluetooth-menu.sh))
    (writeShellScriptBin "confirm-action" (builtins.readFile ./scripts/confirm-action.sh))
  ];
}
