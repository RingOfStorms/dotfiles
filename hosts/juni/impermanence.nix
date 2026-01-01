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
      "/etc/shadow" # keep passwords

      "/etc/NetworkManager/system-connections"
      "/var/lib/bluetooth"
      "/var/lib/NetworkManager"
      "/var/lib/iwd"
      "/var/lib/fail2ban"
    ];
    files = [
      "/etc/machine-id"
    ];
    users."${primaryUser}" = {
      directories = [
        ".ssh"
        ".gnupg"

        "projects"
        ".config/nixos-config"

        ".config/atuin"
        ".local/share/atuin"

        ".local/share/zoxide"

        # KDE
        ".config/kdeconnect"

        # Chrome
        ".config/google-chrome"

        # neovim ros_neovim
        ".local/state/nvim_ringofstorms_helium"
      ];
      files = [

      ];
    };
  };
}
