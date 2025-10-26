{
  config,
  lib,
  pkgs,
  ...
}:
{
  # Caps Lock as Escape for console/tty and Wayland
  console.useXkbConfig = true;
  services.xserver.xkb = {
    layout = "us";
    options = "caps:escape";
  };

  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = [ "gtk" ];
  };

  services.xserver = {
    enable = true;
    # displayManager.startx.enable = true;
    windowManager.i3 = {
      enable = true;
      # package = pkgs.i3;
      extraPackages = with pkgs; [
        dmenu
        i3status
        i3lock
        maim
        xclip
      ];
    };
    desktopManager = {
      # xterm.enable = false;
      # xfce = {
      #   enable = true;
      #   noDesktop = true;
      #   enableXfwm = false;
      # };
    };
    displayManager = {
      lightdm.enable = true;
      defaultSession = "none+i3";
      # defaultSession = "xfce+i3";
    };
  };

  hardware.graphics.enable = true;
}
