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

  environment.systemPackages = with pkgs; [
    # xfce.xfce4-panel
    # xfce.xfce4-session
    # xfce.xfce4-settings
    # xfce.xfce4-power-manager
    # xfce.xfce4-pulseaudio-plugin
    # xfce.xfce4-screenshooter
    # xfce.xfce4-clipman-plugin
    # xfce.xfce4-sensors-plugin
    # xfce.xfce4-notifyd
    pavucontrol
  ];

  # Applets/services for tray widgets
  programs.nm-applet.enable = true;
  services.blueman.enable = true;
  services.upower.enable = true;
  # xfce4-notifyd is provided as a package; XFCE runs it automatically
}
