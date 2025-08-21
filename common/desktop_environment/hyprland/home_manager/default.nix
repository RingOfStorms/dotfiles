{ ... }:
{
  imports = [
    ./theme.nix
    ./hyprland.nix
    ./hyprpanel.nix
    ./hyprpolkitagent.nix
    # ./quickshell.nix # TODO replace hyprpanel with custom quickshell...
    ./wofi.nix
    # ./swaync.nix # notifications, hyprpanel has notifications but I want to replace hyprpanel sometime so keeping this here as reference
    ./swaylock.nix
  ];
}
