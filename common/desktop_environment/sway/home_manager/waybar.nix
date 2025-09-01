{ lib, osConfig, ... }:
let
  ccfg = import ../../../config.nix;
  cfg_path = [ ccfg.custom_config_key "desktopEnvironment" "sway" "waybar" ];
  cfg = lib.attrsets.getAttrFromPath cfg_path osConfig;
in
{
  config = lib.mkIf cfg.enable {
    programs.waybar = {
      enable = true;
      systemd.enable = true;
      settings = {
        mainBar = {
          layer = "top";
          position = "top";
          height = 30;
          spacing = 6;
          margin-top = 0;
          margin-bottom = 0;
          margin-left = 10;
          margin-right = 10;

          modules-left = [ "sway/workspaces" ];
          modules-center = [ "clock" "temperature" "cpu" "memory" "disk" ];
          modules-right = [ "pulseaudio" "network" "bluetooth" "custom/notifications" "sway/language" ];

          "sway/workspaces" = {
            format = "{icon}";
            format-icons = {
              "1" = "一"; "2" = "二"; "3" = "三"; "4" = "四"; "5" = "五";
              "6" = "六"; "7" = "七"; "8" = "八"; "9" = "九"; "10" = "十";
              "11" = "十一"; "12" = "十二"; "13" = "十三"; "14" = "十四"; "15" = "十五";
              "16" = "十六"; "17" = "十七"; "18" = "十八"; "19" = "十九"; "20" = "二十";
            };
            disable-scroll = false;
          };

          pulseaudio = {
            format = "{icon} {volume}%";
            format-bluetooth = "󰂰 {volume}%";
            format-bluetooth-muted = "󰂲 ";
            format-muted = "󰖁 ";
            format-source = "󰍬 {volume}%";
            format-source-muted = "󰍭 ";
            format-icons = {
              headphone = "󰋋";
              hands-free = "󰂑";
              headset = "󰂑";
              phone = "󰏲";
              portable = "󰦧";
              car = "󰄋";
              default = [ "󰕿" "󰖀" "󰕾" ];
            };
            scroll-step = 5;
            on-click = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
            on-click-right = "swaync-client -t -sw";
          };

          "custom/notifications" = {
            format = "{icon} {}";
            format-icons = {
              notification = ""; none = "";
              dnd-notification = "󰂛"; dnd-none = "󰂛";
              inhibited-notification = ""; inhibited-none = "";
              dnd-inhibited-notification = "󰂛"; dnd-inhibited-none = "󰂛";
            };
            return-type = "json";
            exec-if = "which swaync-client";
            exec = "swaync-client -swb";
            on-click = "swaync-client -t -sw";
            on-click-right = "swaync-client -d -sw";
            escape = true;
            tooltip = false;
          };

          clock = { format = "{:%b %d, %H:%M}"; };

          temperature = {
            thermal-zone = 2;
            hwmon-path = "/sys/class/hwmon/hwmon2/temp1_input";
            critical-threshold = 80;
            format-critical = "󰔏 {temperatureC}°C";
            format = "󰔏 {temperatureC}°C";
          };

          cpu = { format = "󰻠 {usage}%"; tooltip = false; on-click = "btop"; };
          memory = { format = "󰍛 {}%"; on-click = "btop"; };
          disk = { interval = 30; format = "󰋊 {percentage_used}%"; path = "/"; on-click = "btop"; };

          network = {
            format-wifi = "󰤨 {essid} ({signalStrength}%)";
            format-ethernet = "󰈀 {ipaddr}/{cidr}";
            tooltip-format = "{ifname} via {gwaddr} ";
            format-linked = "󰈀 {ifname} (No IP)";
            format-disconnected = "󰖪 Disconnected";
            # on-click = "wofi-wifi-menu";
            # on-click-right = "nmcli radio wifi toggle";
          };

          bluetooth = {
            format = "󰂯 {status}";
            format-connected = "󰂱 {device_alias}";
            format-connected-battery = "󰂱 {device_alias} {device_battery_percentage}%";
            tooltip-format = "{controller_alias}\t{controller_address}\n\n{num_connections} connected";
            tooltip-format-connected = "{controller_alias}\t{controller_address}\n\n{num_connections} connected\n\n{device_enumerate}";
            tooltip-format-enumerate-connected = "{device_alias}\t{device_address}";
            tooltip-format-enumerate-connected-battery = "{device_alias}\t{device_address}\t{device_battery_percentage}%";
            # on-click = "wofi-bluetooth-menu";
            # on-click-right = "bluetoothctl power toggle";
          };

          "sway/language" = { format = "{}"; }; # simplified
        };
      };

      style = ''
        * { font-family: "JetBrainsMonoNL Nerd Font"; font-size: 12px; border: none; border-radius: 0; min-height: 0; }
        window#waybar { background: transparent; border-radius: 10px; margin: 0px; }
        .modules-left,.modules-center,.modules-right { background: rgba(26,27,38,.8); border-radius: 10px; margin: 4px; padding: 0 10px; }
        #workspaces { padding: 0 5px; }
        #workspaces button { padding: 0 8px; background: transparent; color: #c0caf5; border-radius: 5px; margin: 2px; }
        #workspaces button:hover { background: rgba(125,196,228,.2); color: #7dcae4; }
        #workspaces button.active { background: #7dcae4; color: #1a1b26; }
        #pulseaudio,#custom-notifications,#clock,#temperature,#cpu,#memory,#disk,#network,#bluetooth,#language { padding: 0 8px; color: #c0caf5; margin: 2px; }
        #temperature.critical { color: #f7768e; }
        #network.disconnected { color: #f7768e; }
        #bluetooth.disabled { color: #565f89; }
        #pulseaudio.muted { color: #565f89; }
      '';
    };
  };
}
