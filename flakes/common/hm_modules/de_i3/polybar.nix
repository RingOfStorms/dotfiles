{ lib, pkgs, ... }:
let
  mf = "#3b3b3bcc";
  bg = "#00000000";
  fg = "#FFFFFF";

  polybarRun = pkgs.writeShellScriptBin "pbr" ''
    polybar -m | while IFS=: read -r mon rest; do
      if echo "$rest" | ${pkgs.gnugrep}/bin/grep -q "(primary)"; then
        MONITOR="$mon" polybar -r primary &
      else
        MONITOR="$mon" polybar -r others &
      fi
    done
    wait
  '';
in
{
  services.polybar = {
    enable = true;
    package = pkgs.polybar.override {
      i3Support = true;
      iwSupport = true;
      pulseSupport = true;
    };
    script = "${polybarRun}/bin/pbr";
    settings = {
      "global/wm" = {
        margin-bottom = 0;
        margin-top = 5;
      };

      "bar/main" = {
        monitor = "\${env:MONITOR}";
        width = "100%";
        height = 20;
        radius = 0;
        background = bg;
        foreground = fg;
        font-0 = "JetBrainsMono Nerd Font:size=11;2";
        font-1 = "Noto Sans CJK JP:size=11;2";

        cursor-click = "pointer";
        enable-ipc = true;
      };

      "bar/primary" = {
        "inherit" = "bar/main";
        modules-left = "i3";
        modules-center = "clock temperature cpu memory filesystem";
        modules-right = "volume tray powermenu";
        # modules-right = "volume network bluetooth backlight tray powermenu";
      };

      "bar/others" = {
        "inherit" = "bar/main";
        modules-left = "i3";
        modules-center = "clock temperature cpu memory filesystem";
        modules-right = "";
      };

      "settings" = {
        screenchange-reload = true;

        compositing-background = "source";
        compositing-foreground = "over";
        compositing-overline = "over";
        comppositing-underline = "over";
        compositing-border = "over";

        pseudo-transparency = true;
      };

      "module/i3" = {
        type = "internal/i3";
        index-sort = true;
        pin-workspaces = true;
        strip-wsnumbers = true;
        wrapping-scroll = false;
        format = "<label-state>";

        ws-icon-0 = "1;一";
        ws-icon-1 = "2;二";
        ws-icon-2 = "3;三";
        ws-icon-3 = "4;四";
        ws-icon-4 = "5;五";
        ws-icon-5 = "6;六";
        ws-icon-6 = "7;七";
        ws-icon-7 = "8;八";
        ws-icon-8 = "9;九";
        ws-icon-9 = "10;十";

        label-unfocused = "%icon%";
        label-focused = "%icon%";
        label-focused-background = mf;
        label-visible = "%icon%";
        label-urgent = "%icon%";
        label-occupied = "%icon%";

        label-unfocused-padding = 1;
        label-focused-padding = 1;
        label-visible-padding = 1;
        label-urgent-padding = 1;
        label-occupied-padding = 1;
      };

      "module/clock" = {
        type = "internal/date";
        interval = 10;
        date = "%b %d, %H:%M";
        format = "<label>";
        label = "%date%";
      };

      "module/temperature" = {
        type = "internal/temperature";
        interval = 5;
        thermal-zone = 2;
        hwmon-path = "/sys/class/hwmon/hwmon2/temp1_input";
        warn-temperature = 80;
        format = "<label>";
        format-prefix = "  ";
        label = "󰔏 %temperature-c%";
      };

      "module/cpu" = {
        type = "internal/cpu";
        interval = 2;
        format = "<label>";
        format-prefix = "  ";
        label = "󰻠 %percentage%%";
      };

      "module/memory" = {
        type = "internal/memory";
        interval = 5;
        format = "<label>";
        format-prefix = "  ";
        label = "󰍛 %percentage_used%%";
      };

      "module/filesystem" = {
        type = "internal/fs";
        interval = 30;
        mount-0 = "/";
        format-mounted = "<label-mounted>";
        label-mounted = "󰋊 %percentage_used%%";
        format-mounted-prefix = "  ";
      };

      # "module/battery" = {
      #   type = "internal/battery";
      #   battery = "BAT0";
      #   adapter = "AC";
      #   full-at = 98;
      #   format-charging = "%percentage%% ";
      #   format-discharging = "%percentage%% %icon%";
      #   format-full = "%percentage%% ";
      #   ramp-capacity-0 = "";
      #   ramp-capacity-1 = "";
      #   ramp-capacity-2 = "";
      #   ramp-capacity-3 = "";
      #   ramp-capacity-4 = "";
      # };
      #
      # "module/battery2" = {
      #   type = "internal/battery";
      #   battery = "BAT2";
      #   adapter = "AC";
      #   full-at = 98;
      #   format-charging = "%percentage%% ";
      #   format-discharging = "%percentage%% %icon%";
      #   format-full = "%percentage%% ";
      #   ramp-capacity-0 = "";
      #   ramp-capacity-1 = "";
      #   ramp-capacity-2 = "";
      #   ramp-capacity-3 = "";
      #   ramp-capacity-4 = "";
      # };

      # "module/volumea" = {
      #   type = "custom/script";
      #   format = "<label>";
      #   exec = "/bin/sh";
      #   exec-args = [
      #     "-c"
      #     "${pkgs.wireplumber}/bin/wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | awk '{printf \"󰕿  %d%%\", $2*100}'"
      #   ];
      #   interval = 2;
      #   click-left = "${pkgs.pavucontrol}/bin/pavucontrol";
      #   click-right = "${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
      #   scroll-up = "${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.05+";
      #   scroll-down = "${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.05-";
      # };

      "module/volume" = {
        type = "internal/alsa";
      };

      # "module/wifi" = {
      #   type = "internal/network";
      #   interface = "wlp11s0";
      #   unknown-as-up = true;
      #   accumulate-stats = true;
      #   interval = 3;
      #   format-connected = "󰤨 %essid% (%signal%%)";
      #   format-wired = "󰈀 %local_ip%";
      #   format-disconnected = "󰖪 Disconnected";
      # };

      # "module/network" = {
      #   type = "internal/network";
      #   interface = "eno1";
      #
      #   interval = "1.0";
      #
      #   accumulate-stats = true;
      #   unknown-as-up = true;
      #
      #   format-connected = "<label-connected>";
      #   format-connected-background = mf;
      #   format-connected-underline = bg;
      #   format-connected-overline = bg;
      #   format-connected-padding = 2;
      #   format-connected-margin = 0;
      #
      #   format-disconnected = "<label-disconnected>";
      #   format-disconnected-background = mf;
      #   format-disconnected-underline = bg;
      #   format-disconnected-overline = bg;
      #   format-disconnected-padding = 2;
      #   format-disconnected-margin = 0;
      #
      #   label-connected = "D %downspeed:2% | U %upspeed:2%";
      #   label-disconnected = "DISCONNECTED";
      # };

      # "module/bluetooth" = {
      #   type = "custom/script";
      #   format = "<label>";
      #   format-prefix = "  ";
      #   exec = "/bin/sh";
      #   exec-args = [
      #     "-c"
      #     "${pkgs.bluez}/bin/bluetoothctl info | grep -q 'Connected: yes' && echo '󰂱' || echo '󰂯 off'"
      #   ];
      #   interval = 5;
      #   click-left = "blueman-manager";
      # };

      # "module/backlight" = {
      #   type = "custom/script";
      #   format = "<label>";
      #   format-prefix = "  ";
      #   exec = "/bin/sh";
      #   exec-args = [
      #     "-c"
      #     "${pkgs.brightnessctl}/bin/brightnessctl -m | cut -d, -f4"
      #   ];
      #
      #   interval = 2;
      #   label = "%output%%  ";
      #   scroll-up = "${pkgs.brightnessctl}/bin/brightnessctl set +5%";
      #   scroll-down = "${pkgs.brightnessctl}/bin/brightnessctl set 5%-";
      # };

      "module/powermenu" = {
        type = "custom/menu";
        expand-right = "false";

        format = "<label-toggle> <menu>";
        format-background = mf;
        format-padding = 1;

        label-open = " ";
        label-close = " ";
        label-separator = "|";

        menu-0-0 = "󰍃 Logout";
        menu-0-0-exec = "i3-msg exit";
        menu-0-1 = " Reboot";
        menu-0-1-exec = "systemctl reboot";
        menu-0-2 = " Shutdown";
        menu-0-2-exec = "systemctl poweroff";
      };

      "module/tray" = {
        type = "internal/tray";
        tray-foreground = fg;
        tray-spacing = 4;
        tray-size = "90%";
        tray-position = "right";
      };
    };
  };

  home.packages = [
    polybarRun

    pkgs.playerctl
    pkgs.brightnessctl
    pkgs.blueman
    pkgs.bluez
    pkgs.noto-fonts-cjk-sans
  ];
}
