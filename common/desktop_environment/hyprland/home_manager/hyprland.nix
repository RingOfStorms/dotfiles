{
  osConfig,
  lib,
  pkgs,
  ...
}:
let
  ccfg = import ../../../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "desktopEnvironment"
    "hyprland"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path osConfig;
in
{
  wayland.windowManager.hyprland = {
    enable = true;
    # set the Hyprland and XDPH packages to null to use the ones from the NixOS module
    package = null;
    portalPackage = null;

    plugins = with pkgs.hyprlandPlugins; [
      hyprspace
    ];

    settings = lib.attrsets.recursiveUpdate {
      # exec-once = [
      #   "waybar"
      # ];

      # Default monitor configuration
      monitor = "monitor = , preferred, auto, 1";

      # Add window rules for hyprpanel stability
      windowrulev2 = [
        "stayfocused, class:^(hyprpanel)$"
        "pin, class:^(hyprpanel)$"
      ];

      # Input configuration
      input = {
        kb_layout = "us";
        kb_options = "caps:escape";

        follow_mouse = 2;
        touchpad = {
          natural_scroll = true;
          disable_while_typing = true;
        };
      };

      # General settings
      general = {
        gaps_in = 2;
        gaps_out = 4;
        border_size = 1;
        "col.active_border" = "rgba(797979aa)";
        "col.inactive_border" = "rgba(393939aa)";
        layout = "dwindle";
      };

      # Decoration
      decoration = {
        rounding = 4;
        blur.enabled = false;
      };

      # Animations
      animations = {
        enabled = false;
      };

      # Layout
      dwindle = {
        pseudotile = true;
        preserve_split = true;
      };

      # Misc
      misc = {
        force_default_wallpaper = 0;
        disable_hyprland_logo = true;
        disable_splash_rendering = true;
      };

      # Key bindings
      "$mainMod" = "SUPER";

      bind = [
        # Applications
        "$mainMod, Return, exec, ${cfg.terminalCommand}"
        "$mainMod, Space, exec, pkill wofi || wofi --show drun"
        "$mainMod, q, killactive"
        "$mainMod SHIFT, q, exec, hyprlock"
        "$mainMod, f, togglefloating"
        "$mainMod, g, pseudo"
        "$mainMod, t, togglesplit"

        # Move focus with mainMod + hjkl
        "$mainMod, h, movefocus, l"
        "$mainMod, l, movefocus, r"
        "$mainMod, k, movefocus, u"
        "$mainMod, j, movefocus, d"

        # Switch workspaces with mainMod + [0-9]
        "$mainMod, 1, workspace, 1"
        "$mainMod, 2, workspace, 2"
        "$mainMod, 3, workspace, 3"
        "$mainMod, 4, workspace, 4"
        "$mainMod, 5, workspace, 5"
        "$mainMod, 6, workspace, 6"
        "$mainMod, 7, workspace, 7"
        "$mainMod, 8, workspace, 8"
        "$mainMod, 9, workspace, 9"
        "$mainMod, 0, workspace, 10"

        # Window management (similar to your GNOME setup)
        "$mainMod SHIFT, h, movewindow, l"
        "$mainMod SHIFT, l, movewindow, r"
        "$mainMod SHIFT, k, movewindow, u"
        "$mainMod SHIFT, j, movewindow, d"
        "$mainMod SHIFT, n, movetoworkspace, m+1"
        "$mainMod SHIFT, p, movetoworkspace, m-1"

        # Screenshots
        ", Print, exec, grimblast copy area"
      ];

      bindr = [
        # overview
        "$mainMod, SUPER_L, overview:toggle, all"
      ];

      binde = [
        # Move between workspaces
        "$mainMod, n, workspace, r+1"
        "$mainMod, p, workspace, r-1"

        # Resize windows
        "$mainMod CTRL, h, resizeactive, -40 0"
        "$mainMod CTRL, l, resizeactive, 40 0"
        "$mainMod CTRL, k, resizeactive, 0 -20"
        "$mainMod CTRL, j, resizeactive, 0 20"
      ];

      # Mouse bindings
      bindm = [
        "$mainMod, mouse:272, movewindow"
        "$mainMod, mouse:273, resizewindow"
      ];
    } cfg.extraOptions;
  };
}
