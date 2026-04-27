{ primaryUser }:
{ ... }:
{
  environment.persistence."/persist" = {
    enable = true;
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      "/var/lib/systemd/timers"

      "/etc/nixos"
      "/etc/ssh"

      "/etc/NetworkManager/system-connections"
      "/var/lib/bluetooth"
      "/var/lib/NetworkManager"
      "/var/lib/iwd"
      "/var/lib/fail2ban"

      "/var/lib/tailscale"

      "/var/lib/upower"

      # PipeWire Bluetooth device state (profiles, routing, codec selection)
      "/var/lib/pipewire"

      # cached timezone name for offline restore
      "/var/lib/timezone-cache"

      "/var/lib/flatpak"

      # bao secrets
      "/run/openbao"
      "/var/lib/openbao-secrets"
    ];
    files = [
      "/machine-key.json"
      "/etc/machine-id"
      "/etc/adjtime"
      # NOTE: if you want mutable passwords across reboots, persist these,
      # but you must do a one-time migration (see notes in chat).
      # "/etc/shadow"
      # "/etc/group"
      # "/etc/passwd"
      # "/etc/sudoers"
    ];
    users."${primaryUser}" = {
      directories = [
        "Downloads"
        "Documents"
        "Desktop"
        "Public"
        "Videos"
        "Pictures"

        ".ssh"
        ".gnupg"

        "projects"
        ".config/nixos-config"

        ".config/atuin"
        ".local/share/atuin"

        ".local/share/zoxide"

        # tmux resurrect session persistence
        ".local/share/tmux"

        # Hugging Face cache (e.g. whisper.cpp models via hf-hub)
        ".cache/huggingface"

        ".config/pulse"
        ".config/direnv"
        ".config/opencode"
        ".local/share/opencode"

        # KDE
        ".config/kdeconnect"

        # Chrome
        ".config/google-chrome"

        ".local/share/baloo"
        ".local/state/wireplumber"

        # KDE Plasma monitor layout (hardware-specific, not declarative)
        ".local/share/kscreen"

        # neovim ros_neovim
        ".local/state/nvim_ringofstorms_helium"
        ".local/state/opencode"

        ".local/share/flatpak"
        ".var/app"

        # Jellyfin Media Player (server list, login, settings)
        ".local/share/jellyfin-desktop"
        ".config/jellyfinmediaplayer"

        # work profile chrome
        ".config/google-chrome-tempus"

        # LM Studio: downloaded models, chats, settings, and bundled runtime
        # (~/.lmstudio is multi-GB once you've pulled a model)
        ".lmstudio"

        # --- Plasma config persistence ---
        # With impermanence, ~/.config and ~/.local/share are wiped each boot.
        # SDDM autologin starts plasmashell *before* HM activation has rewritten
        # its configs, so plasmashell briefly reads stock defaults — visible as
        # a "flash" of default wallpaper / panels / theme before the real config
        # kicks in. Persisting these means plasmashell renders correctly on
        # first paint after each boot. With `programs.plasma.overrideConfig =
        # true` (in flakes/de_plasma/home_manager/default.nix), plasma-manager
        # wipes & rewrites managed keys on every activation, so persisted files
        # never drift from declared state — runtime-only keys (recent docs,
        # window positions) survive harmlessly.
        # First boot after enabling: persist files don't exist yet, so the
        # very first login still flashes. Every subsequent boot is clean.
        ".config/plasma-workspace" # session/autostart state, ksmserver lock
        ".local/share/plasma" # plasmoid/widget runtime data
        ".local/share/color-schemes" # custom color schemes
      ];
      files = [
        # Plasma 6 KWin monitor output configuration (hardware-specific)
        ".config/kwinoutputconfig.json"

        # --- Plasma config persistence (see directories block above) ---
        # Desktop containment + applet layout (panels, widgets, wallpaper plugin).
        ".config/plasma-org.kde.plasma.desktop-appletsrc"
        ".config/plasmashellrc"
        ".config/plasmarc"
        # KWin: window manager settings, rules, virtual desktops, scripts.
        ".config/kwinrc"
        ".config/kwinrulesrc"
        # Shortcuts: global + khotkeys.
        ".config/kglobalshortcutsrc"
        ".config/khotkeysrc"
        # KDE-wide look/feel: color scheme, fonts, icons, cursor.
        ".config/kdeglobals"
        # Lock screen appearance + behavior.
        ".config/kscreenlockerrc"
        # Session manager (logout/restore behavior).
        ".config/ksmserverrc"
        # Activities.
        ".config/kactivitymanagerdrc"
        # Keyboard layout (xkb).
        ".config/kxkbrc"
        # File manager + terminal (declared via plasma-manager).
        ".config/dolphinrc"
        ".config/konsolerc"
        # Baloo file indexer (disabled declaratively).
        ".config/baloofilerc"
        # KWallet (disabled declaratively).
        ".config/kwalletrc"
        # Notification position/behavior.
        ".config/plasmanotifyrc"
        # KRunner search bar.
        ".config/krunnerrc"
        # System Settings application state.
        ".config/systemsettingsrc"
        # Spectacle screenshot tool defaults.
        ".config/spectaclerc"
        # Breeze widget style settings.
        ".config/breezerc"
        # Qt5 settings (cursor size, fonts) — read by all Qt apps at startup.
        ".config/Trolltech.conf"
      ];
    };
  };
}
