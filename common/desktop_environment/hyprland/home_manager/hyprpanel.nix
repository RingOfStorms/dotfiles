{
  pkgs,
  lib,
  ...
}:
{
  home.packages = with pkgs; [
    # aylurs-gtk-shell-git
    wireplumber
    libgtop
    bluez
    bluez-tools
    networkmanager
    dart-sass
    wl-clipboard
    upower
    gvfs
    gtksourceview3
    libchamplain_libsoup3 # libsoup3
    ## Used for Tracking GPU Usage in your Dashboard (NVidia only)
    # python
    # python-gpustat
    ## To control screen/keyboard brightness
    brightnessctl
    ## Only if a pywal hook from wallpaper changes applied through settings is desired
    # pywal
    ## To check for pacman updates in the default script used in the updates module
    # pacman-contrib
    ## To switch between power profiles in the battery module
    power-profiles-daemon
    ## To take snapshots with the default snapshot shortcut in the dashboard
    grimblast
    ## To record screen through the dashboard record shortcut
    wf-recorder
    ## To enable the eyedropper color picker with the default snapshot shortcut in the dashboard
    hyprpicker
    ## To enable hyprland's very own blue light filter
    hyprsunset
    ## To click resource/stat bars in the dashboard and open btop
    btop
    ## To enable matugen based color theming
    # matugen
    ## To enable matugen based color theming and setting wallpapers
    # swww
  ];
  # xdg.configFile.hyprpanel.target =  lib.mkForce "hyprpanel/config.generated.json";
  programs.hyprpanel = {
    enable = true;
    settings = {
      bar.layouts = {
        "DP-1" = {
          left = [
            # "dashboard"
            "workspaces"
            "media"
            "volume"
            "systray"
            "cava"
          ];

          middle = [
            "notifications"
            "clock"
            "cputemp"
            "cpu"
            "ram"
            "storage"
          ];

          right = [
            "netstat"
            "network"
            "bluetooth"
            # "battery"
            # "updates"
            "kbinput"
            "power"
          ];
        };
        "*" = {
          left = [
            "workspaces"
          ];
          middle = [
            "clock"
          ];
          right = [ ];
        };
      };
      bar.workspaces = {
        # workspaces = 10;
        show_icons = false;
        show_numbered = false;
        showWsIcons = true;
        showApplicationIcons = false;
        workspaceMask = true;
        workspaceIconMap = {
          "1" = "一"; # "1" いち | ひとつ
          "2" = "二"; # "2" に | ふたつ
          "3" = "三"; # "3" さん | みっつ
          "4" = "四"; # "4" し | よん
          "5" = "五"; # "5" ご | いつつ
          "6" = "六"; # "6" ろく | むっつ
          "7" = "七"; # "7" しち | ななつ
          "8" = "八"; # "8" はち | やっつ
          "9" = "九"; # "9" きゅう | ここのつ
          "10" = "十"; # "10" じゅう | とお
        };
      };
      notifications.ignore = [ "spotify" ];
      customModules = {
        cava = {
          showActiveOnly = true;
          showIcon = false;
          icon = "";
        };
      };
      theme = {
        matugen = false;
        name = "tokyo-night-vivid";

        font = {
          name = "JetBrainsMonoNL Nerd Font Regular";
          size = "12px";
        };
        bar = {
          transparent = true;
          floating = true;
          outer_spacing = "0px";
          margin_bottom = "0px";
          margin_top = "0px";
          margin_sides = "0px";
        };

      };
      wallpaper = {
        enable = false;
        image = "";
      };

    };
  };
}
