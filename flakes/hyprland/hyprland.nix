{
  config,
  lib,
  pkgs,
  hyprland,
  hyprlandPkgs,
  ...
}:
with lib;
{
  # Enable for all users
  home-manager = {
    sharedModules = [
      hyprland.homeManagerModules.default
      ./home_manager
    ];
  };

  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --remember --remember-session --cmd '${pkgs.dbus}/bin/dbus-run-session ${hyprlandPkgs.hyprland}/bin/Hyprland'";
        user = "greeter";
      };
    };
  };

  # Caps Lock as Escape for console/tty
  console.useXkbConfig = true;
  services.xserver.xkb = {
    layout = "us";
    options = "caps:escape";
  };

  environment.systemPackages = with pkgs; [
    wl-clipboard
    wl-clip-persist
    wofi # application launcher
    nemo # file manager (x11)
    # nautilus # file manager
    feh # image viewer (x11)
    # imv # image viewer
    networkmanager # network management
    upower # power management
    brightnessctl # screen/keyboard brightness control
    wireplumber # media session manager
    libgtop # system monitor library
    bluez # Bluetooth support
    power-profiles-daemon # power profiles
    grim
    slurp
    hyprpicker
    grimblast # screenshot tool
    wf-recorder # screen recording tool
    btop # system monitor
  ];

  services.blueman.enable = config.hardware.bluetooth.enable;

  programs.hyprland = {
    enable = true;
    # xwayland.enable = false;
    # withUWSM = true;

    # set the flake package
    package = hyprlandPkgs.hyprland;
    # make sure to also set the portal package, so that they are in sync
    # This is set below now in xdf portal directly so we can also add things like gtk
    # portalPackage = hyprlandPkgs.xdg-desktop-portal-hyprland;
  };

  xdg.portal = {
    enable = true;
    extraPortals = lib.mkForce [
      hyprlandPkgs.xdg-desktop-portal-hyprland
      # hyprlandPkgs.xdg-desktop-portal-wlr
      hyprlandPkgs.xdg-desktop-portal-gtk
    ];
    config.common.default = [
      "hyprland"
      # "wlr"
      "gtk"
    ];
  };

  # Enable PipeWire + WirePlumber so xdg-desktop-portal can do screencast
  services.pipewire = {
    enable = true;
    # Enable WirePlumber session manager via the pipewire module option
    wireplumber = {
      enable = true;
    };
  };

  hardware.graphics = {
    enable = true;
    package = hyprlandPkgs.mesa;
    # if you also want 32-bit support (e.g for Steam)
    # enable32Bit = true;
    package32 = hyprlandPkgs.pkgsi686Linux.mesa;
  };

  # Environment variables
  environment.sessionVariables = {
    GTK_THEME = "Adwaita:dark";
    XDG_SESSION_TYPE = "wayland";
    # XDG_CURRENT_DESKTOP = "sway";
    # XDG_SESSION_DESKTOP = "sway";
    # prefer EGL renderer (can be changed back to "auto" if needed)
    WLR_RENDERER = "egl";

    # Tell apps to run native wayland
    NIXOS_OZONE_WL = "1";
    ELECTRON_OZONE_PLATFORM_HINT = "wayland";
    ELECTRON_ENABLE_WAYLAND = "1";
    ELECTRON_DISABLE_SANDBOX = "0";
    GDK_BACKEND = "wayland,x11"; # GTK
    QT_QPA_PLATFORM = "wayland;xcb"; # Qt 5/6
    MOZ_ENABLE_WAYLAND = "1"; # Firefox
    SDL_VIDEODRIVER = "wayland"; # SDL apps/games
    CLUTTER_BACKEND = "wayland";
  };

  # Qt theming
  qt = {
    enable = true;
    platformTheme = "gtk2";
    style = "adwaita-dark";
  };
}
