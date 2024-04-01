{ pkgs, ... }:
{
  services.xserver = {
    enable = true;
    displayManager.gdm = {
      enable = true;
      autoSuspend = false;
      wayland = true;
    };
    desktopManager.gnome.enable = true;
  };
  services.gnome.core-utilities.enable = false;
  environment.systemPackages = with pkgs; [
    gnome.dconf-editor
    gnomeExtensions.workspace-switch-wraparound
    # wayland clipboard in terminal
    wl-clipboard
  ];
}

