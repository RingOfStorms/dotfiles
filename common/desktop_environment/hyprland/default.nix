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
        default = "kitty";
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
        ./home_manager
      ];
    };

    # Display Manager
    services = {
      displayManager = {
        sddm = {
          enable = true;
          wayland.enable = true;
        };
      };
    };

    # Caps Lock as Escape for console/tty
    console.useXkbConfig = true;
    services.xserver.xkb = {
      layout = "us";
      options = "caps:escape";
    };
    hardware.graphics.enable = true;

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
      grimblast # screenshot tool
      wf-recorder # screen recording tool
      btop # system monitor
    ];

    services.blueman.enable = config.hardware.bluetooth.enable;

    programs.hyprland = {
      enable = true;
      xwayland.enable = true;
      withUWSM = true;
    };

    # Environment variables
    environment.sessionVariables = {
      NIXOS_OZONE_WL = "1";
      GTK_THEME = "Adwaita:dark";
      XDG_SESSION_TYPE = "wayland";
      XDG_CURRENT_DESKTOP = "Hyprland";
      XDG_SESSION_DESKTOP = "Hyprland";
      ELECTRON_OZONE_PLATFORM_HINT = "wayland";
    };

    # Qt theming
    qt = {
      enable = true;
      platformTheme = "gtk2";
      style = "adwaita-dark";
    };
  };
}
