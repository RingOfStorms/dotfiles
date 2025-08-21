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
      wofi
      nemo
      feh
    ];

    programs.hyprland = {
      enable = true;
      xwayland.enable = true;
      withUWSM = true;
    };

    # Environment variables
    environment.sessionVariables = {
      NIXOS_OZONE_WL = "1";
      GTK_THEME = "Adwaita:dark";
    };

    # Qt theming
    qt = {
      enable = true;
      platformTheme = "gtk2";
      style = "adwaita-dark";
    };
  };
}
