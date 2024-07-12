{ pkgs, ... }:
{
  services.xserver = {
    enable = true;
    displayManager.gdm = {
      enable = true;
      autoSuspend = false;
      wayland = false;
    };
    desktopManager.gnome.enable = true;
  };
  services.gnome.core-utilities.enable = false;
  environment.systemPackages = with pkgs; [
    gnome.dconf-editor
    xclip
  ];
}

