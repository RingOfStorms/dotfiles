{
  pkgs,
  settings,
  lib,
  nixConfig,
  ...
}:
with lib.hm.gvariant;
{
  home.packages = with pkgs; [
    # use `dconf dump /` before and after and diff the files for easy editing of dconf below
    # > `dconf dump / > /tmp/dconf_dump_start && watch -n0.5 "dconf dump / > /tmp/dconf_dump_current && diff --color /tmp/dconf_dump_start /tmp/dconf_dump_current -U12"`
    # OR (Must be logged into user directly, no SU to user will work): `dconf watch /`
    # OR get the exact converted nixConfig from `dconf dump / | dconf2nix | less` and search with forward slash
    # gnome.dconf-editor
    # gnomeExtensions.workspace-switch-wraparound
    #gnomeExtensions.forge # probably don"t need on this on tiny laptop but may explore this instead of sway for my desktop
  ];

  dconf = lib.mkIf (!nixConfig.mods.de_cosmic.enable) {
    enable = true;
    settings = {
      "org/gnome/desktop/session" = {
        idle-delay = mkUint32 0;
      };
      "org/gnome/shell" = {
        favorite-apps = [
          "Alacritty.desktop"
          "firefox-esr.desktop"
          "org.gnome.Nautilus.desktop"
          "spotify.desktop"
          "discord.desktop"
        ];
        # enabled-extensions = with pkgs.gnomeExtensions; [
        #   workspace-switch-wraparound.extensionUuid 
        # ];
      };
      "org/gnome/desktop/interface" = {
        color-scheme = "prefer-dark";
        enable-hot-corners = false;
        show-battery-percentage = true;
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
        command = "alacritty";
        name = "Launch terminal";
      };
      "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1" = {
        binding = "<Super>Space";
        command =
          if nixConfig.mods.de_gnome_xorg.enable then
            "rofi -show"
          else if nixConfig.mods.de_gnome_wayland.enable then
            "wofi --show drun"
          else
            ""; # fallback in case neither is enabled
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
        move-to-workspace-left = [ "<Control><Super>h" ];
        move-to-workspace-right = [ "<Control><Super>l" ];
        switch-input-source = [ ];
        switch-input-source-backward = [ ];
        switch-to-workspace-1 = [ "<Super>1" ];
        switch-to-workspace-2 = [ "<Super>2" ];
        switch-to-workspace-3 = [ "<Super>3" ];
        switch-to-workspace-4 = [ "<Super>4" ];
        switch-to-workspace-last = [ "" ];
        switch-to-workspace-down = [ "" ];
        switch-to-workspace-up = [ "" ];
        switch-to-workspace-left = [ "<Super>k" ];
        switch-to-workspace-right = [ "<Super>j" ];
        move-to-monitor-down = [ "<Control><Super><Shift>j" ];
        move-to-monitor-up = [ "<Control><Super><Shift>k" ];
        move-to-monitor-left = [ "<Control><Super><Shift>h" ];
        move-to-monitor-right = [ "<Control><Super><Shift>l" ];
        unmaximize = [ "<Super><Shift>j" ];
        maximize = [ "<Super>m" ];
      };
      "org/gnome/mutter" = {
        dynamic-workspaces = true;
        edge-tiling = true;
        workspaces-only-on-primary = true;
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
        picture-uri = "file://" + (settings.usersDir + "/_common/components/black.png");
        picture-uri-dark = "file://" + (settings.usersDir + "/_common/components/black.png");
        primary-color = "#000000000000";
        secondary-color = "#000000000000";
      };
      "org/gnome/desktop/screensaver" = {
        lock-enabled = false;
        idle-activation-enabled = false;
        picture-options = "zoom";
        picture-uri = "file://" + (settings.usersDir + "/_common/components/black.png");
        picture-uri-dark = "file://" + (settings.usersDir + "/_common/components/black.png");
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
    };
  };
}
