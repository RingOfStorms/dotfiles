{ cfg }:
{
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf cfg.enable {
    home-manager.sharedModules = [
      (
        { lib, ... }:
        with lib.hm.gvariant;
        {
          # use `dconf dump /` before and after and diff the files for easy editing of dconf below
          #     dconf dump / > /tmp/dconf_dump_start && watch -n0.5 "dconf dump / > /tmp/dconf_dump_current && \diff --color /tmp/dconf_dump_start /tmp/dconf_dump_current -U12"
          # To get nix specific diff:
          #     \diff -u /tmp/dconf_dump_start /tmp/dconf_dump_current | grep '^+[^+]' | sed 's/^+//' | dconf2nix
          # OR (Must be logged into user directly, no SU to user will work): `dconf watch /`
          # OR get the exact converted nixConfig from `dconf dump / | dconf2nix | less` and search with forward slash
          dconf.settings = {
            "org/gnome/shell" = {
              favorite-apps = [ ];
              enabled-extensions = with pkgs.gnomeExtensions; [
                vertical-workspaces.extensionUuid
                compact-top-bar.extensionUuid
                tray-icons-reloaded.extensionUuid
                vitals.extensionUuid
              ] ++ lib.optionals cfg.enableRotate [
                screen-rotate.extensionUuid
              ];
            };

            # Plugin Settings
            "org/gnome/shell/extensions/vertical-workspaces" = {
              animation-speed-factor = 42;
              center-dash-to-ws = false;
              dash-bg-color = 0;
              dash-position = 2;
              dash-position-adjust = 0;
              hot-corner-action = 0;
              startup-state = 1;
              ws-switcher-wraparound = true;
            };
            "org/gnome/shell/extensions/compact-top-bar" = {
              fade-text-on-fullscreen = true;
            };
            "org/gnome/shell/extensions/vitals" = {
              position-in-panel = 1;
            };

            # Built in settings
            "org/gnome/desktop/session" = {
              idle-delay = mkUint32 0;
            };
            "org/gnome/desktop/wm/preferences" = {
              resize-with-right-button = true;
              button-layout = "maximize:appmenu,close";
              audible-bell = false;
              wrap-around = true;
            };
            "org/gnome/settings-daemon/plugins/media-keys" = {
              # Disable the lock screen shortcut
              screensaver = [ "" ];
              custom-keybindings = [
                "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
                "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/"
              ];
            };
            "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
              binding = "<Super>Return";
              command = cfg.terminalCommand;
              name = "Launch terminal";
            };
            "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1" = {
              binding = "<Super>Space";
              command = "wofi";
              name = "Launcher";
            };
            "org/gnome/desktop/wm/keybindings" = {
              minimize = [ "" ];
              move-to-workspace-1 = [ "" ];
              move-to-workspace-2 = [ "" ];
              move-to-workspace-3 = [ "" ];
              move-to-workspace-4 = [ "" ];
              move-to-workspace-last = [ "" ];
              move-to-workspace-down = [ "<Control><Super>j" ];
              move-to-workspace-up = [ "<Control><Super>k" ];
              # move-to-workspace-left = [ "<Control><Super>h" ];
              # move-to-workspace-right = [ "<Control><Super>l" ];
              switch-input-source = [ ];
              switch-input-source-backward = [ ];
              switch-to-workspace-1 = [ "<Super>1" ];
              switch-to-workspace-2 = [ "<Super>2" ];
              switch-to-workspace-3 = [ "<Super>3" ];
              switch-to-workspace-4 = [ "<Super>4" ];
              switch-to-workspace-last = [ "" ];
              switch-to-workspace-down = [ "<Super>j" ];
              switch-to-workspace-up = [ "<Super>k" ];
              # switch-to-workspace-left = [ "<Super>k" ];
              # switch-to-workspace-right = [ "<Super>j" ];
              # move-to-monitor-down = [ "<Control><Super><Shift>j" ];
              # move-to-monitor-up = [ "<Control><Super><Shift>k" ];
              move-to-monitor-left = [ "<Control><Super>h" ];
              move-to-monitor-right = [ "<Control><Super>l" ];
              unmaximize = [ "<Super><Shift>j" ];
              maximize = [ "<Super><Shift>k" ];
            };
            "org/gnome/mutter" = {
              dynamic-workspaces = true;
              edge-tiling = true;
              workspaces-only-on-primary = true;
              center-new-windows = true;
            };
            "org/gnome/mutter/keybindings" = {
              toggle-tiled-right = [ "<Super><Shift>l" ];
              toggle-tiled-left = [ "<Super><Shift>h" ];
            };
            "org/gnome/settings-daemon/plugins/power" = {
              power-button-action = "nothing";
              sleep-inactive-ac-type = "nothing";
              sleep-inactive-battery-type = "nothing";
              idle-brightness = 15;
              power-saver-profile-on-low-battery = false;
            };
            "org/gnome/desktop/background" = {
              color-shading-type = "solid";
              picture-options = "zoom";
              picture-uri = "file://" + (./black.png);
              picture-uri-dark = "file://" + (./black.png);
              primary-color = "#000000000000";
              secondary-color = "#000000000000";
            };
            "org/gnome/desktop/screensaver" = {
              lock-enabled = false;
              idle-activation-enabled = false;
              picture-options = "zoom";
              picture-uri = "file://" + (./black.png);
              picture-uri-dark = "file://" + (./black.png);
            };
            "org/gnome/desktop/applications/terminal" = {
              exec = "alacritty";
            };
            "org/gnome/settings-daemon/plugins/color" = {
              night-light-enabled = false;
              night-light-schedule-automatic = false;
            };
            "org/gnome/shell/keybindings" = {
              shift-overview-down = [ "" ];
              shift-overview-up = [ "" ];
              switch-to-application-1 = [ "" ];
              switch-to-application-2 = [ "" ];
              switch-to-application-3 = [ "" ];
              switch-to-application-4 = [ "" ];
              switch-to-application-5 = [ "" ];
              switch-to-application-6 = [ "" ];
              switch-to-application-7 = [ "" ];
              switch-to-application-8 = [ "" ];
              switch-to-application-9 = [ "" ];
              toggle-quick-settings = [ "" ];
              toggle-application-view = [ "" ];
            };
            "org/gtk/gtk4/settings/file-chooser" = {
              show-hidden = true;
            };

            "org/gnome/desktop/interface" = {
              accent-color = "orange";
              show-battery-percentage = true;
              clock-show-date = true;
              clock-show-seconds = true;
              clock-show-weekday = true;
              color-scheme = "prefer-dark";
              cursor-size = 24;
              enable-animations = true;
              enable-hot-corners = false;
              font-antialiasing = "grayscale";
              font-hinting = "slight";
              gtk-theme = "Adwaita-dark";
              # icon-theme = "Yaru-magenta-dark";
            };

            "org/gnome/desktop/notifications" = {
              application-children = [ "org-gnome-tweaks" ];
            };

            "org/gnome/desktop/notifications/application/org-gnome-tweaks" = {
              application-id = "org.gnome.tweaks.desktop";
            };

            "org/gnome/desktop/peripherals/mouse" = {
              natural-scroll = false;
            };

            "org/gnome/desktop/peripherals/touchpad" = {
              disable-while-typing = true;
              two-finger-scrolling-enabled = true;
              natural-scroll = true;
            };

            "org/gnome/tweaks" = {
              show-extensions-notice = false;
            };
          };
        }
      )
    ];
  };
}
