# Impermanence persistence declarations for joe (primary desktop/gaming rig)
# Defines what survives a reboot. Everything else resets to a clean state.
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
      # NOTE: /etc/ssh is NOT persisted here. The impermanence module's SSH fix
      # points sshd host keys directly at /persist/etc/ssh/. Bind-mounting
      # /etc/ssh hides the NixOS-generated sshd_config, breaking sshd.

      "/etc/NetworkManager/system-connections"
      "/var/lib/bluetooth"
      "/var/lib/NetworkManager"
      "/var/lib/iwd"
      "/var/lib/fail2ban"

      "/var/lib/upower"

      # cached timezone name for offline restore
      "/var/lib/timezone-cache"

      # Steam persists its own library, config, and compatdata here
      "/var/lib/steam"

      # Flatpak (system-wide installs and runtime data)
      "/var/lib/flatpak"
    ];
    files = [
      "/etc/machine-id"
      "/etc/adjtime"
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

        ".config/pulse"
        ".config/direnv"
        ".config/opencode"
        ".local/share/opencode"

        # KDE
        ".config/kdeconnect"

        # KDE Plasma monitor layout persistence
        ".local/share/kscreen"

        # Chrome
        ".config/google-chrome"

        ".local/share/baloo"
        ".local/state/wireplumber"

        # neovim
        ".local/state/nvim_ringofstorms_helium"
        ".local/state/opencode"

        # Steam user data (saves, configs, shader caches, compatdata)
        ".local/share/Steam"
        ".steam"

        # Jellyfin Media Player (server list, login, settings)
        ".local/share/jellyfinmediaplayer"

        # Flatpak (user installs and app data)
        ".local/share/flatpak"
        ".var/app"
      ];
      files = [
        # Plasma 6 KWin monitor output configuration
        ".config/kwinoutputconfig.json"
      ];
    };
  };
}
