{
  config,
  lib,
  pkgs,
  ...
}:
{
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
      ];
    };
    desktopManager = {
      xterm.enable = true;
      xfce = {
        enable = true;
        noDesktop = true;
        enableXfwm = false;
      };
    };
    displayManager = {
      # lightdm.enable = true;
      defaultSession = "xfce+i3";
    };
  };

  services.greetd = {
    enable = true;
    vt = 2;
    settings = {
      default_session = {
        command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --remember --remember-session --cmd '${pkgs.dbus}/bin/dbus-run-session ${pkgs.xorg.xinit}/bin/startx ${pkgs.xfce.xfce4-session}/bin/startxfce4 -- ${pkgs.xorg.xorgserver}/bin/X -keeptty -quiet vt${toString config.services.greetd.vt}'";
        user = "greeter";
      };
    };
  };

  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = [ "gtk" ];
  };
}
