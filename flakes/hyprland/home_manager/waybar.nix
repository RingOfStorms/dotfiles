{ lib, ... }:
{
  programs.waybar = {
    enable = true;
    systemd.enable = true;
    settings = {
      mainBar = {
        layer = "top";
        position = "top";
        height = 28;
        spacing = 6;
        margin-top = 0;
        margin-bottom = 0;
        margin-left = 10;
        margin-right = 10;

        modules-left = [
          "hyprland/workspaces"
        ];
        modules-center = [
          "clock"
          "temperature"
          "cpu"
          "memory"
          "disk"
        ];
        modules-right = [
          "battery"
          "battery#bat2"
          "pulseaudio"
          "network"
          "bluetooth"
          "power-profiles-daemon"
          "backlight"
          "custom/notifications"
          "tray"
          "custom/power"
        ];

        "hyprland/workspaces" = {
          format = "{icon}";
          format-icons = {
            "1" = "一";
            "2" = "二";
            "3" = "三";
            "4" = "四";
            "5" = "五";
            "6" = "六";
            "7" = "七";
            "8" = "八";
            "9" = "九";
            "10" = "十";
            "11" = "十一";
            "12" = "十二";
            "13" = "十三";
            "14" = "十四";
            "15" = "十五";
            "16" = "十六";
            "17" = "十七";
            "18" = "十八";
            "19" = "十九";
            "20" = "二十";
          };
          disable-scroll = false;
        };

        # CENTER
        clock = {
          format = "{:%b %d, %H:%M}";
          tooltip-format = "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>";
        };

        temperature = {
          thermal-zone = 2;
          hwmon-path = "/sys/class/hwmon/hwmon2/temp1_input";
          critical-threshold = 80;
          format-critical = "󰔏 {temperatureC}°C";
          format = "󰔏 {temperatureC}°C";
        };

        cpu = {
          format = "󰻠 {usage}%";
          tooltip = true;
          on-click = "btop";
        };

        memory = {
          format = "󰍛 {}%";
          on-click = "btop";
        };

        disk = {
          interval = 30;
          format = "󰋊 {percentage_used}%";
          path = "/";
          on-click = "btop";
        };

        # RIGHT
        "battery" = {
          "states" = {
            # "good"= 95;
            "warning" = 30;
            "critical" = 15;
          };
          "format" = "{capacity}% {icon}";
          "format-full" = "{capacity}% {icon}";
          "format-charging" = "{capacity}% ";
          "format-plugged" = "{capacity}% ";
          "format-alt" = "{time} {icon}";
          # "format-good"= ""; // An empty format will hide the module
          # "format-full"= "";
          "format-icons" = [
            ""
            ""
            ""
            ""
            ""
          ];
        };
        "battery#bat2" = {
          "bat" = "BAT2";
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
            default = [
              "󰕿"
              "󰖀"
              "󰕾"
            ];
          };
          scroll-step = 5;
          on-click = "pavucontrol";
          on-click-right = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
        };

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

        "power-profiles-daemon" = {
          format = "{icon}";
          "tooltip-format" = "Power profile: {profile}\nDriver: {driver}";
          tooltip = true;
          "format-icons" = {
            default = "";
            performance = "";
            balanced = "";
            "power-saver" = "";
          };
        };

        backlight = {
          format = "{percent}% {icon}";
          "format-icons" = [
            ""
            ""
            ""
            ""
            ""
            ""
            ""
            ""
            ""
          ];
        };

        "custom/notifications" = {
          format = "{icon} {}";
          format-icons = {
            notification = "";
            none = "";
            dnd-notification = "󰂛";
            dnd-none = "󰂛";
            inhibited-notification = "";
            inhibited-none = "";
            dnd-inhibited-notification = "󰂛";
            dnd-inhibited-none = "󰂛";
          };
          return-type = "json";
          exec-if = "which swaync-client";
          exec = "swaync-client -swb";
          on-click = "swaync-client -t -sw";
          on-click-right = "swaync-client -d -sw";
          escape = true;
          tooltip = false;
        };

        "sway/language" = {
          format = "{}";
        };

        "tray" = {
          "spacing" = 10;
        };

        "custom/power" = {
          format = "⏻ ";
          tooltip = false;
          menu = "on-click";
          "menu-file" = ./waybar/power_menu.xml;
          "menu-actions" = {
            shutdown = "shutdown 0";
            reboot = "reboot";
            logout = "loginctl terminate-session $(loginctl list-sessions | grep seat0 | awk '{print $1}')";
          };
        };

      };
    };

    style = builtins.readFile ./waybar/waybar.css;
  };
}
