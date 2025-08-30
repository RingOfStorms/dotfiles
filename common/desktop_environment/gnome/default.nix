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
    "gnome"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
in
with lib;
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "gnome desktop environment";
      terminalCommand = mkOption {
        type = lib.types.str;
        default = "kitty";
        description = "The terminal command to use.";
      };
      enableRotate = lib.mkEnableOption "enable screen rotation";
    };

  imports = [
    (import ./dconf.nix { inherit cfg; })
    (import ./wofi.nix { inherit cfg; })
  ];

  config = lib.mkIf cfg.enable {
    services.xserver = {
      enable = true;
      desktopManager.gnome.enable = true;
      displayManager.gdm = {
        enable = true;
        autoSuspend = false;
        wayland = true;
      };
    };
    services.gnome.gnome-initial-setup.enable = false;

    environment.gnome.excludePackages = with pkgs; [
      gnome-backgrounds
      gnome-video-effects
      gnome-maps
      gnome-music
      gnome-tour
      gnome-text-editor
      gnome-user-docs
    ];
    environment.systemPackages = with pkgs; [
      dconf-editor
      dconf2nix
      gnome-tweaks
      wayland
      wayland-utils
      # xwayland
      wl-clipboard
      numix-cursor-theme
      gnomeExtensions.vertical-workspaces
      gnomeExtensions.compact-top-bar
      gnomeExtensions.tray-icons-reloaded
      gnomeExtensions.vitals
    ] ++ lib.optionals cfg.enableRotate [
      gnomeExtensions.screen-rotate
    ];
    environment.sessionVariables = {
      NIXOS_OZONE_WL = "1";
      GTK_THEME = "Adwaita:dark";
    };

    qt = {
      enable = true;
      platformTheme = "gnome";
      style = "adwaita-dark";
    };

    hardware.graphics = {
      enable = true;
    };
  };
}
