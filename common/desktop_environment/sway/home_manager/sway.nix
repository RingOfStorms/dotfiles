{
  config,
  osConfig,
  lib,
  ...
}:
let
  ccfg = import ../../../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "desktopEnvironment"
    "sway"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path osConfig;
in
{
  wayland.windowManager.sway = {
    enable = true;
    xwayland = true;

     config = lib.mkMerge [
       rec {
         modifier = "Mod4"; # SUPER
         terminal = cfg.terminalCommand;
         menu = "wofi --show drun";
 
         # Per-output workspace mapping (user can extend via extraOptions)
         # Example (left as defaults): users can add `output HDMI-A-1 workspace 1,3,5` in extraOptions
 
         input = {
           "type:keyboard" = {
             xkb_layout = "us";
             xkb_options = "caps:escape";
           };
           "type:touchpad" = {
             natural_scroll = "enabled";
             tap = "enabled";
             dwt = "enabled";
           };
           # Disable focus follows mouse to avoid accidental focus changes
           # In Sway this behavior is controlled by focus_follows_mouse
         };
 
         focus = {
           followMouse = "no";
           # onWindowActivation = "urgent"; # don't steal focus; mark urgent instead
         };
 
         gaps = {
           inner = 2;
           outer = 4;
           smartGaps = false;
           smartBorders = "on";
         };
 
         window = {
           border = 1;
           titlebar = false;
           commands = [
             # Bitwarden chrome popup as floating example from Hyprland rules
             {
               criteria = {
                 class = "chrome-nngceckbapebfimnlniiiahkandclblb-Default";
                 title = "_crx_nngceckbapebfimnlniiiahkandclblb";
                 instance = ".*";
               };
               command = "floating enable, move position center, resize set 720 600";
             }
           ];
         };
 
         # Keybindings mirroring Hyprland
         keybindings = {
           # Apps
           "${modifier}+return" = "exec ${cfg.terminalCommand}";
           "${modifier}+space" = "exec pkill wofi || wofi --show drun";
           "${modifier}+q" = "kill";
           "${modifier}+shift+Escape" = "exit";
           "${modifier}+shift+q" = "exec swaylock";
           "${modifier}+f" = "floating toggle";
 
           # Focus
           "${modifier}+h" = "focus left";
           "${modifier}+l" = "focus right";
           "${modifier}+k" = "focus up";
           "${modifier}+j" = "focus down";
 
           # Workspaces (numbers and vim-like mirror)
           "${modifier}+1" = "workspace number 1";
           "${modifier}+n" = "workspace number 1";
           "${modifier}+2" = "workspace number 2";
           "${modifier}+m" = "workspace number 2";
           "${modifier}+3" = "workspace number 3";
           "${modifier}+comma" = "workspace number 3";
           "${modifier}+4" = "workspace number 4";
           "${modifier}+period" = "workspace number 4";
           "${modifier}+5" = "workspace number 5";
           "${modifier}+slash" = "workspace number 5";
           "${modifier}+6" = "workspace number 6";
           "${modifier}+7" = "workspace number 7";
           "${modifier}+8" = "workspace number 8";
           "${modifier}+9" = "workspace number 9";
           "${modifier}+0" = "workspace number 10";
 
           # Move windows
           "${modifier}+shift+h" = "move left";
           "${modifier}+shift+l" = "move right";
           "${modifier}+shift+k" = "move up";
           "${modifier}+shift+j" = "move down";
           "${modifier}+shift+1" = "move container to workspace number 1";
           "${modifier}+shift+n" = "move container to workspace number 1";
           "${modifier}+shift+2" = "move container to workspace number 2";
           "${modifier}+shift+m" = "move container to workspace number 2";
           "${modifier}+shift+3" = "move container to workspace number 3";
           "${modifier}+shift+comma" = "move container to workspace number 3";
           "${modifier}+shift+4" = "move container to workspace number 4";
           "${modifier}+shift+period" = "move container to workspace number 4";
           "${modifier}+shift+5" = "move container to workspace number 5";
           "${modifier}+shift+slash" = "move container to workspace number 5";
           "${modifier}+shift+6" = "move container to workspace number 6";
           "${modifier}+shift+7" = "move container to workspace number 7";
           "${modifier}+shift+8" = "move container to workspace number 8";
           "${modifier}+shift+9" = "move container to workspace number 9";
           "${modifier}+shift+0" = "move container to workspace number 10";
 
           # Mouse bindings (Mod + drag)
           "${modifier}+button1" = "move";
           "${modifier}+button3" = "resize";
 
           # Screenshot
           "Print" = "exec grim -g \"$(slurp)\" - | wl-copy";
         };
 
         bars = [ ]; # Use Waybar via Home Manager
         startup = [ { command = "pgrep waybar >/dev/null || waybar"; } ];
       }
       cfg.extraOptions
     ];
  };
}
