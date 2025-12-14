{
  utils,
  pkgs,
  ...
}:
let
  BOOT = "/dev/disk/by-uuid/ABDB-2A38";
  PRIMARY_UUID = "08610781-26d3-456f-9026-35dd4a40846f";
  PRIMARY = "/dev/disk/by-uuid/${PRIMARY_UUID}";

  USB_KEY = "/dev/disk/by-uuid/9985-EBD1";

  inherit (utils) escapeSystemdPath;

  primaryDeviceUnit = "${escapeSystemdPath PRIMARY}.device";
in
{
  # BOOT
  fileSystems."/boot" = {
    device = BOOT;
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
    ];
  };

  # PRIMARY
  fileSystems."/" = {
    device = PRIMARY;
    fsType = "bcachefs";
    options = [
      "X-mount.subdir=@root"
    ];
  };
  fileSystems."/.old_roots" = {
    device = PRIMARY;
    fsType = "bcachefs";
    options = [
      "nofail" # this may not exist yet just skip it
      "X-mount.mkdir"
      "X-mount.subdir=@old_roots"
    ];
  };
  fileSystems."/nix" = {
    device = PRIMARY;
    fsType = "bcachefs";
    options = [
      "X-mount.mkdir"
      "X-mount.subdir=@nix"
      "relatime"
    ];
  };
  fileSystems."/.snapshots" = {
    device = PRIMARY;
    fsType = "bcachefs";
    options = [
      "X-mount.mkdir"
      "X-mount.subdir=@root"
      "relatime"
    ];
  };
  fileSystems."/.swap" = {
    device = PRIMARY;
    fsType = "bcachefs";
    options = [
      "X-mount.mkdir"
      "X-mount.subdir=@swap"
      "noatime"
    ];
  };
  # (optional) for preservation/impermanence
  fileSystems."/persist" = {
    device = PRIMARY;
    fsType = "bcachefs";
    options = [
      "X-mount.mkdir"
      "X-mount.subdir=@persist"
    ];
  };

  # SWAP
  swapDevices = [
    # {
    #   device = "/.swap/swapfile";
    #   size = 8 * 1024; # Creates an 8GB swap file
    # }
  ];

  # PRIMARY unencrypt
  boot.initrd.systemd.enable = true;
  boot.initrd.systemd.packages = [ pkgs.keyutils ];
  boot.supportedFilesystems = [
    "bcachefs"
    "vfat"
  ];

  # 1. Disable the automatically generated unlock services
  boot.initrd.systemd.services = {
    # the module creates services named unlock-bcachefs-<escaped-mountpoint>
    "unlock-bcachefs-${escapeSystemdPath "/"}".enable = false;
    "unlock-bcachefs-${escapeSystemdPath "/.old_roots"}".enable = false;
    "unlock-bcachefs-${escapeSystemdPath "/nix"}".enable = false;
    "unlock-bcachefs-${escapeSystemdPath "/.snapshots"}".enable = false;
    "unlock-bcachefs-${escapeSystemdPath "/.swap"}".enable = false;
    "unlock-bcachefs-${escapeSystemdPath "/persist"}".enable = false;

    # 2. Your single custom unlock unit
    unlock-bcachefs-custom = {
      description = "Custom single bcachefs unlock for all subvolumes";

      wantedBy = [ "initrd.target" ];
      before = [ "sysroot.mount" ];

      requires = [ primaryDeviceUnit ];
      after = [ primaryDeviceUnit ];

      # NOTE: put the real password here, or better: read it from USB_KEY
      # ExecStart = ''
      #   /bin/sh -c 'echo "password" | ${pkgs.bcachefs-tools}/bin/bcachefs unlock ${PRIMARY}'
      # '';
      # ExecStart = ''
      #   /bin/sh -c 'mount -o ro ${USB_KEY} /key && \
      #     cat /key/bcachefs.key | ${pkgs.bcachefs-tools}/bin/bcachefs unlock ${PRIMARY}'
      # '';

      # We inline a script that roughly mimics tryUnlock + openCommand behavior,
      # but uses a key file from the USB stick instead of systemd-ask-password.
      script = ''
        echo "Using test password..."
        keyctl link @u @s
        echo "test" | ${pkgs.bcachefs-tools}/bin/bcachefs unlock -k session "${PRIMARY}"
        echo "bcachefs unlock successful for ${PRIMARY}"
      '';

    };
  };

  # TODO this works for resetting root!
  # boot.initrd.postResumeCommands = lib.mkAfter ''
  #   echo "test" | bcachefs unlock ${PRIMARY}
  #
  #   mkdir /primary_tmp
  #   mount ${PRIMARY} primary_tmp/
  #   if [[ -e /primary_tmp/@root ]]; then
  #       mkdir -p /primary_tmp/@old_roots
  #       bcachefs set-file-option /primary_tmp/@old_roots --compression=zstd
  #
  #       timestamp=$(date --date="@$(stat -c %Y /primary_tmp/@root)" "+%Y-%m-%-d_%H:%M:%S")
  #       bcachefs subvolume snapshot /primary_tmp/@root "/primary_tmp/@old_roots/$timestamp"
  #       bcachefs subvolume delete /primary_tmp/@root
  #   fi
  #
  #   for i in $(find /primary_tmp/old_roots/ -maxdepth 1 -mtime +30); do
  #       bcachefs subvolume delete "$i"
  #   done
  #
  #   bcachefs subvolume create /primary_tmp/@root
  #   umount /primary_tmp
  # '';
}
