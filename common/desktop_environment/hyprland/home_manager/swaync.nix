{
  ...
}:
{
  services.swaync = {
    enable = true;
    settings = {
      ignore = [
        "com.spotify.Client"
      ];

      positionX = "right";
      positionY = "top";
      layer = "overlay";
      control-center-layer = "top";
      layer-shell = true;
      cssPriority = "application";

      control-center-margin-top = 0;
      control-center-margin-bottom = 0;
      control-center-margin-right = 0;
      control-center-margin-left = 0;

      notification-2fa-action = true;
      notification-inline-replies = false;
      notification-icon-size = 64;
      notification-body-image-height = 100;
      notification-body-image-width = 200;

      timeout = 10;
      timeout-low = 5;
      timeout-critical = 0;

      control-center-width = 500;
      control-center-height = 600;
      notification-window-width = 500;

      keyboard-shortcuts = true;
      image-visibility = "when-available";
      transition-time = 200;
      hide-on-clear = false;
      hide-on-action = true;
      script-fail-notify = true;

      widgets = [
        "inhibitors"
        "title"
        "dnd"
        "volume"
        "backlight"
        "mpris"
        "buttons-grid#quick"
        "notifications"
      ];

      # Widget configurations
      widget-config = {
        inhibitors = {
          text = "Inhibitors";
          button-text = "Clear All";
          clear-all-button = true;
        };
        title = {
          text = "Notifications";
          clear-all-button = true;
          button-text = "Clear All";
        };
        dnd.text = "Do Not Disturb";
        mpris = {
          image-size = 96;
          image-radius = 12;
        };
        volume = {
          label = "󰕾";
          show-per-app = true;
        };
        backlight = {
          label = "󰃟";
          device = "intel_backlight";
        };
        "buttons-grid#quick" = {
          columns = 4; # adjust: 3/4/5
          icon-size = 20; # tweak to taste
          actions = [
            # Power
            {
              label = "󰐥";
              tooltip = "Shutdown";
              command = "systemctl poweroff";
            }
            {
              label = "󰜉";
              tooltip = "Reboot";
              command = "systemctl reboot";
            }
            {
              label = "󰍃";
              tooltip = "Logout";
              command = "hyprctl dispatch exit";
            }
            {
              label = "󰤄";
              tooltip = "Suspend";
              command = "systemctl suspend";
            }

            # Network (requires NetworkManager/nmcli)
            {
              label = "󰖪";
              tooltip = "Toggle Wi‑Fi";
              command = "nmcli radio wifi toggle";
            }
            {
              label = "󰖩";
              tooltip = "Wi‑Fi Settings";
              command = "nm-connection-editor";
            }

            # Bluetooth (requires bluez/bluetoothctl, blueman optional)
            {
              label = "󰂲";
              tooltip = "Toggle Bluetooth";
              command = "bluetoothctl power toggle";
            }
            {
              label = "󰂯";
              tooltip = "Bluetooth Settings";
              command = "blueman-manager";
            }
          ];
        };
      };
    };

    # Custom CSS for the control center
    style = ''
      .control-center {
        background: #1a1b26;
        border: 2px solid #7dcae4;
        border-radius: 12px;
      }

      .control-center-list {
        background: transparent;
      }

      .control-center .notification-row:focus,
      .control-center .notification-row:hover {
        opacity: 1;
        background: #24283b;
      }

      .notification {
        border-radius: 8px;
        margin: 6px 12px;
        box-shadow: 0 0 0 1px rgba(125, 196, 228, 0.3), 0 1px 3px 1px rgba(0, 0, 0, 0.7), 0 2px 6px 2px rgba(0, 0, 0, 0.3);
        padding: 0;
      }

      /* Widget styling */
      .widget-title {
        margin: 8px;
        font-size: 1.5rem;
        color: #c0caf5;
      }

      .widget-dnd {
        margin: 8px;
        font-size: 1.1rem;
        color: #c0caf5;
      }

      .widget-dnd > switch {
        font-size: initial;
        border-radius: 8px;
        background: #414868;
        border: 1px solid #7dcae4;
      }

      .widget-dnd > switch:checked {
        background: #7dcae4;
      }

      .widget-mpris {
        color: #c0caf5;
        background: #24283b;
        padding: 8px;
        margin: 8px;
        border-radius: 8px;
      }

      .widget-mpris-player {
        padding: 8px;
        margin: 8px;
      }

      .widget-mpris-title {
        font-weight: bold;
        font-size: 1.25rem;
      }

      .widget-mpris-subtitle {
        font-size: 1.1rem;
        color: #9ece6a;
      }

      .widget-volume {
        background: #24283b;
        padding: 8px;
        margin: 8px;
        border-radius: 8px;
        color: #c0caf5;
      }

      .widget-backlight {
        background: #24283b;
        padding: 8px;
        margin: 8px;
        border-radius: 8px;
        color: #c0caf5;
      }

      .widget-menubar {
        background: #24283b;
        padding: 8px;
        margin: 8px;
        border-radius: 8px;
        color: #c0caf5;
      }

      .widget-menubar .menu-item button {
        background: #1f2335;
        color: #c0caf5;
        border-radius: 8px;
        padding: 6px 10px;
        margin: 4px;
        border: 1px solid #2e3440;
        font-family: "JetBrainsMonoNL Nerd Font";
      }

      .widget-menubar .menu-item button:hover {
        background: #414868;
        border-color: #7dcae4;
      }

      .topbar-buttons button {
        border: none;
        background: transparent;
        color: #c0caf5;
        font-size: 1.1rem;
        border-radius: 8px;
        margin: 0 4px;
        padding: 8px;
      }

      .topbar-buttons button:hover {
        background: #414868;
      }

      .topbar-buttons button:active {
        background: #7dcae4;
        color: #1a1b26;
      }
    '';
  };
}
