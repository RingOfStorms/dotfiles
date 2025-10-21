{
  osConfig,
  lib,
  pkgs,
  upkgs,
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
  home.packages = with pkgs; [
    upkgs.quickshell
    pulseaudio
    brightnessctl
    networkmanager
    bluez
    bluez-tools
    power-profiles-daemon
    upower
    systemd
    hyprlock
  ];

  # Ensure CLI quickshell can resolve modules when not using --config-path
  home.sessionVariables = {
    QML_IMPORT_PATH = "$HOME/.config/quickshell";
    QML2_IMPORT_PATH = "$HOME/.config/quickshell";
  };

  # install config files
  home.file = {
    ".config/quickshell/shell.qml".source = ./quickshell/shell.qml;
    ".config/quickshell/panels/TopBar.qml".source = ./quickshell/panels/TopBar.qml;
    ".config/quickshell/notifications/NotificationServer.qml".source =
      ./quickshell/notifications/NotificationServer.qml;
    ".config/quickshell/notifications/NotificationPopup.qml".source =
      ./quickshell/notifications/NotificationPopup.qml;
    ".config/quickshell/notifications/NotificationCenter.qml".source =
      ./quickshell/notifications/NotificationCenter.qml;
    ".config/quickshell/widgets/status/Workspaces.qml".source =
      ./quickshell/widgets/status/Workspaces.qml;
    ".config/quickshell/widgets/status/Clock.qml".source = ./quickshell/widgets/status/Clock.qml;
    ".config/quickshell/widgets/status/SystemTrayWidget.qml".source =
      ./quickshell/widgets/status/SystemTrayWidget.qml;
    ".config/quickshell/widgets/status/Battery.qml".source = ./quickshell/widgets/status/Battery.qml;
    ".config/quickshell/widgets/controls/QuickSettings.qml".source =
      ./quickshell/widgets/controls/QuickSettings.qml;
    ".config/quickshell/widgets/controls/Audio.qml".source = ./quickshell/widgets/controls/Audio.qml;
    ".config/quickshell/widgets/controls/Network.qml".source =
      ./quickshell/widgets/controls/Network.qml;
    ".config/quickshell/widgets/controls/Bluetooth.qml".source =
      ./quickshell/widgets/controls/Bluetooth.qml;
    ".config/quickshell/widgets/controls/Brightness.qml".source =
      ./quickshell/widgets/controls/Brightness.qml;
    ".config/quickshell/widgets/controls/PowerProfilesWidget.qml".source =
      ./quickshell/widgets/controls/PowerProfilesWidget.qml;
    ".config/quickshell/panels/qmldir".source = ./quickshell/panels/qmldir;
    ".config/quickshell/notifications/qmldir".source = ./quickshell/notifications/qmldir;
    ".config/quickshell/widgets/status/qmldir".source = ./quickshell/widgets/status/qmldir;
    ".config/quickshell/widgets/controls/qmldir".source = ./quickshell/widgets/controls/qmldir;
    # optional: .qmlls.ini should be gitignored; create empty to enable LSP
    ".config/quickshell/.qmlls.ini".text = "";
  };

  systemd.user.services.quickshell = {
    Unit = {
      Description = "Quickshell Desktop Shell";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${upkgs.quickshell}/bin/quickshell --config-path %h/.config/quickshell";
      Restart = "on-failure";
      RestartSec = 2;
      Environment = [
        "QML_IMPORT_PATH=%h/.config/quickshell"
        "QT_QPA_PLATFORM=wayland"
        # Ensure we find icons
        "XDG_CURRENT_DESKTOP=quickshell"
      ];
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
