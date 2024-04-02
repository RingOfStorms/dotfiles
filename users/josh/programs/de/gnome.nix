{ pkgs, lib, ... }:
with lib.hm.gvariant;
{
  home.packages = with pkgs; [
    # use `dconf dump /` before and after and diff the files for easy editing of dconf below
    # > `dconf dump / > /tmp/dconf_dump_start && watch -n0.5 'dconf dump / > /tmp/dconf_dump_current && diff --color /tmp/dconf_dump_start /tmp/dconf_dump_current -U12'`
    # OR (Must be logged into user directly, no SU to user will work): `dconf watch /`
    # OR get the exact converted config from `dconf dump / | dconf2nix | less` and search with forward slash
    # gnome.dconf-editor
    # gnomeExtensions.workspace-switch-wraparound
    #gnomeExtensions.forge # probably don't need on this on tiny laptop but may explore this instead of sway for my desktop
  ];

  dconf = {
    enable = true;
    settings = {
      "org/gnome/desktop/session" = {
        idle-delay = mkUint32 0;
      };
      "org/gnome/shell" = {
        favorite-apps = [
          # "vivaldi-stable.desktop"
          "Alacritty.desktop"
          # Wezterm is not playing nice with me on gnome wayland :(
          # "org.wezfurlong.wezterm.desktop"
          "firefox.desktop"
          "org.gnome.Nautilus.desktop"
        ];
        enabled-extensions = with pkgs.gnomeExtensions; [
          workspace-switch-wraparound.extensionUuid
        ];
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
        custom-keybindings = [ "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/" ];
      };
      "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
        binding = "<Super>Return";
        command = "alacritty";
        name = "Launch terminal";
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

        switch-to-workspace-1 = [ "<Super>1" ];
        switch-to-workspace0 = [ "<Super>2" ];
        switch-to-workspace-3 = [ "<Super>3" ];
        switch-to-workspace-4 = [ "<Super>4" ];
        switch-to-workspace-down = [ "" ];
        switch-to-workspace-last = [ "" ];
        switch-to-workspace-left = [ "<Super>h" ];
        switch-to-workspace-right = [ "<Super>l" ];
      };
      "org/gnome/mutter" = {
        edge-tiling = true;
        workspaces-only-on-primary = true;
      };
      "org/gnome/settings-daemon/plugins/power" = {
        power-button-action = "nothing";
        sleep-inactive-ac-type = "nothing";
        sleep-inactive-battery-type = "nothing";
        idle-brightness = 15;
        power-saver-profile-on-low-battery = false;
      };
      "org/gnome/desktop/screensaver" = {
        lock-enabled = false;
        idle-activation-enabled = false;
      };
      "org/gnome/desktop/applications/terminal" = {
        exec = "alacritty";
      };
      "org/gnome/settings-daemon/plugins/color" = {
        night-light-enabled = false;
        night-light-schedule-automatic = false;
      };
      "org/gnome/shell/keybindings" = {
        shift-overview-down = [ "<Super>j" ];
        shift-overview-up = [ "<Super>k" ];
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
        toggle-application-view = [ "<Super>space" ];
      };
      "org/gtk/gtk4/settings/file-chooser" = {
        show-hidden = true;
      };
    };
  };
}
