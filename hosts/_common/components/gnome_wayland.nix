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
    dconf-editor
    # wayland clipboard in terminal
    wl-clipboard
  ];
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
}

