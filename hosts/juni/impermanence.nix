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

        # --- Plasma directory-level persistence ---
        # With impermanence, ~/.config and ~/.local/share are wiped each boot.
        # Directory bind-mounts are safe with KDE's atomic-rename writes;
        # individual *file* bind-mounts are NOT — KDE rewrites them via
        # write-tmp-then-rename, which detaches the bind mount and leaves the
        # persisted copy stale/empty. So we only persist directories here.
        ".config/plasma-workspace" # session/autostart state, ksmserver lock
        ".local/share/plasma" # plasmoid/widget runtime data
        ".local/share/color-schemes" # custom color schemes

        # NOTE: Tried persisting plasma-manager's `last_run_*` markers (either
        # directly via `.local/share/plasma-manager` or via a shadow dir at
        # `.local/state/plasma-manager-markers`) to skip plasma-manager's
        # post-login apply scripts and eliminate the brief "flash of defaults"
        # visible on each login. It DOES NOT WORK because plasma-manager's
        # apply scripts mutate runtime state (in particular, panels and
        # wallpaper are written into `~/.config/plasma-org.kde.plasma.desktop-appletsrc`
        # via qdbus calls to the running plasmashell — they're not persistent
        # config writes). The markers track script-content hashes, not desktop
        # state, so persisted markers + wiped appletsrc → skip-but-no-state
        # → defaults render permanently. Reverted; accept the brief flash.
      ];
      files = [
        # Plasma 6 KWin monitor output configuration (hardware-specific).
        # NOTE: this is a JSON file written by KWin on output-config changes;
        # acceptable as a single-file bind because writes are infrequent.
        ".config/kwinoutputconfig.json"
      ];
    };
  };
}
