{
  config,
  lib,
  pkgs,
  hyprland,
  hyprlandPkgs,
  ...
}:
let
  ccfg = import ../../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "desktopEnvironment"
    "hyprland"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
in
with lib;
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "hyprland desktop environment";
      terminalCommand = mkOption {
        type = lib.types.str;
        default = "foot";
        description = "The terminal command to use.";
      };
      extraOptions = mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra options for Hyprland configuration.";
      };
      swaync = {
        enable = lib.mkEnableOption "Enable Swaync (notification center for Hyprland)";
      };
      waybar = {
        enable = lib.mkEnableOption "Enable Waybar (status bar for Hyprland)";
      };
    };

  config = lib.mkIf cfg.enable {
    # Enable for all users
    home-manager = {
      sharedModules = [
        hyprland.homeManagerModules.default
        ./home_manager
      ];
    };

    services.greetd = {
      enable = true;
      vt = 2;
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
      nemo # file manager
      feh # image viewer
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
      # xwayland.enable = true;
      withUWSM = true;

      # set the flake package
      package = hyprlandPkgs.hyprland;
      # make sure to also set the portal package, so that they are in sync
      portalPackage = hyprlandPkgs.xdg-desktop-portal-hyprland;
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
      NIXOS_OZONE_WL = "1";
      GTK_THEME = "Adwaita:dark";
      XDG_SESSION_TYPE = "wayland";
      XDG_CURRENT_DESKTOP = "Hyprland";
      XDG_SESSION_DESKTOP = "Hyprland";
      ELECTRON_OZONE_PLATFORM_HINT = "wayland";
      CLUTTER_BACKEND = "wayland";
      WLR_RENDERER = "vulkan";
    };

    # Qt theming
    qt = {
      enable = true;
      platformTheme = "gtk2";
      style = "adwaita-dark";
    };
  };
}
