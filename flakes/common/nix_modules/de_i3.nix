{
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
    windowManager.i3 = {
      enable = true;
      extraPackages = with pkgs; [
        dmenu
        maim
        xclip
      ];
    };
    displayManager = {
      lightdm.enable = true;
    };
  };
  services.displayManager.defaultSession = "none+i3";

  hardware.graphics.enable = true;
  security.rtkit.enable = true;

  # Applets/services for tray widgets
  programs.nm-applet.enable = true;
  services.blueman.enable = true;
  services.upower.enable = true;
}
