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
      "/var/lib/fail2ban"
    ];
    files = [
      "/etc/machine-id"
    ];
    users.luser = {
      directories = [
        "projects"
        ".config/nixos-config"

        ".config/atuin"
        ".local/share/atuin"

        ".local/share/zoxide"

        # KDE connect specific
        ".config/kdeconnect"

        ".local/state/nvim_ringofstorms_helium"
      ];
      files = [

      ];
    };
  };
}
