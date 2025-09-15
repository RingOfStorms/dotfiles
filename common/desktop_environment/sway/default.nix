{
  config,
  lib,
  pkgs,
  ...
}:
let
  ccfg = import ../../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "desktopEnvironment"
    "sway"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
in
with lib;
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "sway (Wayland i3) desktop environment";
      terminalCommand = mkOption {
        type = lib.types.str;
        default = "foot";
        description = "The terminal command to use.";
      };
      extraOptions = mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra options for Sway configuration.";
      };
      swaync = {
        enable = lib.mkEnableOption "Enable Sway Notification Center";
      };
      waybar = {
        enable = lib.mkEnableOption "Enable Waybar (status bar for Sway)";
      };
    };

  config = lib.mkIf cfg.enable {
    # Enable for all users via Home Manager fragments in this module
    home-manager = {
      sharedModules = [ ./home_manager ];
    };

    services.greetd = {
      enable = true;
      vt = 2;
      settings = {
        default_session = {
          command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --remember --remember-session --cmd '${pkgs.dbus}/bin/dbus-run-session ${pkgs.sway}/bin/sway'";
          user = "greeter";
        };
      };
    };

    # Caps Lock as Escape for console/tty and Wayland
    console.useXkbConfig = true;
    services.xserver.xkb = {
      layout = "us";
      options = "caps:escape";
    };

    # Core packages and tools
    environment.systemPackages = with pkgs; [
      wl-clipboard
      wl-clip-persist
      wofi # application launcher
      nemo # file manager (x11)
      feh # image viewer (x11)
      networkmanager
      upower
      brightnessctl
      wireplumber
      libgtop
      bluez
      power-profiles-daemon
      grim
      slurp
      wf-recorder
      btop
      pavucontrol
    ];

    services.blueman.enable = config.hardware.bluetooth.enable;

    programs.sway = {
      enable = true;
      wrapperFeatures.gtk = true; # include GTK integration env
      extraPackages = with pkgs; [
        xwayland # allow legacy X11 apps
      ];
    };

    xdg.portal = {
      enable = true;
      extraPortals = lib.mkForce [
        pkgs.xdg-desktop-portal-wlr
        pkgs.xdg-desktop-portal-gtk
      ];
      config.common.default = [
        "wlr"
        "gtk"
      ];
    };

    hardware.graphics = {
      enable = true;
      # Keep defaults; Sway runs fine with mesa in system
    };

    # Environment variables
    environment.sessionVariables = lib.mkMerge [
      {
        GTK_THEME = "Adwaita:dark";
        XDG_SESSION_TYPE = "wayland";
        XDG_CURRENT_DESKTOP = "sway";
        XDG_SESSION_DESKTOP = "sway";
        WLR_RENDERER = "auto";

        # Tell apps to run native wayland
        NIXOS_OZONE_WL = "1";
        ELECTRON_OZONE_PLATFORM_HINT = "wayland";
        GDK_BACKEND = "wayland,x11"; # GTK
        QT_QPA_PLATFORM = "wayland;xcb"; # Qt 5/6
        MOZ_ENABLE_WAYLAND = "1"; # Firefox
        SDL_VIDEODRIVER = "wayland"; # SDL apps/games
        CLUTTER_BACKEND = "wayland";
      }
    ];

    # Qt theming
    qt = {
      enable = true;
      platformTheme = "gtk2";
      style = "adwaita-dark";
    };
  };
}
