{ ... }:
{
  preservation = {
    enable = true;

    # Preserve system-wide directories and files at /persist
    preserveAt = {
      "/persist" = {
        commonMountOptions = [
          "x-gvfs-hide"
          "x-gdu.hide"
        ];

        # Directories to persist (bind-mount by default)
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
        ];

        # Files to persist
        files = [
          # Persist machine-id early (initrd) via symlink for ConditionFirstBoot compatibility
          { file = "/etc/machine-id"; inInitrd = true; how = "symlink"; configureParent = true; }

          # SSH host keys: ensure correct handling with symlinks
          { file = "/etc/ssh/ssh_host_rsa_key"; how = "symlink"; configureParent = true; }
          { file = "/etc/ssh/ssh_host_ed25519_key"; how = "symlink"; configureParent = true; }
        ];

        # Per-user persistence
        users = {
          luser = {
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
            files = [ ];
          };
        };
      };
    };
  };

  # Configure intermediate system-wide directories that may need custom modes
  # (Example: none required beyond defaults here.)

  # Let systemd-machine-id-commit write the transient ID to the persistent volume.
  # This avoids activation failure when /etc/machine-id is a symlink.
  systemd.services.systemd-machine-id-commit = {
    unitConfig.ConditionPathIsMountPoint = [
      ""
      "/persist/etc/machine-id"
    ];
    serviceConfig.ExecStart = [
      ""
      "systemd-machine-id-setup --commit --root /persist"
    ];
  };

  # If you need custom ownership/modes for parent directories, use tmpfiles:
  # systemd.tmpfiles.settings.preservation = {
  #   "/foo".d = { user = "foo"; group = "bar"; mode = "0775"; };
  #   "/foo/bar".d = { user = "bar"; group = "bar"; mode = "0755"; };
  # };
}
