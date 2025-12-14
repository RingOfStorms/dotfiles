{ lib, pkgs, ... }:
let
  BOOT = "/dev/disk/by-uuid/ABDB-2A38";
  PRIMARY = "/dev/disk/by-uuid/08610781-26d3-456f-9026-35dd4a40846f";

  USB_KEY = "/dev/disk/by-uuid/9985-EBD1";
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
  # TODO how to auto unencrypt with options...
  # - USB key
  # - TPM
  # boot.initrd.availableKernelModules = [ "bcachefs" ];
  # boot.initrd.extraUtilsCommands = ''
  #   copy_bin_and_libs ${pkgs.bcachefs-tools}/bin/bcachefs
  # '';
  #
  # # Method 1, prompt user for password on boot
  # boot.initrd.preDeviceCommands = ''
  #   ${pkgs.bcachefs-tools}/bin/bcachefs unlock ${PRIMARY}
  # '';

  # # Run unlock before devices are scanned/mounted
  # boot.initrd.preDeviceCommands = ''
  #   echo "Unlocking bcachefs..."
  #   # Example: ask for a passphrase
  #   /bin/echo -n "Bcachefs passphrase: "
  #   /bin/stty -echo
  #   read PASSPHRASE
  #   /bin/stty echo
  #   echo
  #
  #   # Use the passphrase to unlock the device
  #   # Replace /dev/disk/by-uuid/XXXX with your actual device
  #   echo "$PASSPHRASE" | ${pkgs.bcachefs-tools}/bin/bcachefs unlock /dev/disk/by-uuid/XXXX
  # '';
  # boot.initrd.systemd.enable = true;
  boot.supportedFilesystems = [
    "bcachefs"
    "vfat"
  ];
  boot.initrd.extraUtilsCommands = ''
    copy_bin_and_libs ${pkgs.bcachefs-tools}/bin/bcachefs
    copy_bin_and_libs ${pkgs.keyutils}/bin/keyctl
  '';
  # boot.initrd.systemd.services.unlock-primary = {
  #   description = "Unlock bcachefs root with key";
  #   wantedBy = [ "initrd-root-device.target" ];
  #   before = [ "initrd-root-device.target" ];
  #   unitConfig.DefaultDependencies = "no";
  #   serviceConfig = {
  #     Type = "oneshot";
  #     # Wait for USB disk; you can refine this with udev-based Wants=/Requires=
  #     ExecStart = pkgs.writeShellScript "bcachefs-unlock-initrd" ''
  #       set -eu
  #       ${pkgs.keyutils}/bin/keyctl link @u @s
  #       echo "test" | ${pkgs.bcachefs-tools}/bin/bcachefs unlock ${PRIMARY}
  #       exit 0
  #     '';
  #   };
  # };
  # boot.initrd.systemd.services.unlock-primary = {
  #   description = "Unlock bcachefs root with key";
  #   wantedBy = [ "initrd-root-device.target" ];
  #   before = [ "initrd-root-device.target" ];
  #   unitConfig.DefaultDependencies = "no";
  #   serviceConfig = {
  #     Type = "oneshot";
  #     # Wait for USB disk; you can refine this with udev-based Wants=/Requires=
  #     ExecStart = pkgs.writeShellScript "bcachefs-unlock-initrd" ''
  #       echo "Waiting for USB key with label SECRETKEY..."
  #       for i in $(seq 1 20); do
  #         if [ -e /dev/disk/by-label/SECRETKEY ]; then
  #           break
  #         fi
  #         sleep 0.5
  #       done
  #
  #       if [ ! -e /dev/disk/by-label/SECRETKEY ]; then
  #         echo "USB key not found; failing."
  #         exit 1
  #       fi
  #
  #       mkdir -p /mnt-key
  #       mount -t vfat /dev/disk/by-label/SECRETKEY /mnt-key
  #
  #       echo "Unlocking bcachefs..."
  #       ${pkgs.bcachefs-tools}/bin/bcachefs unlock \
  #         --keyfile /mnt-key/bcachefs.key \
  #         /dev/disk/by-uuid/YOUR_BCACHEFS_UUID
  #
  #       umount /mnt-key
  #     '';
  #   };
  # };

  boot.initrd.postResumeCommands = lib.mkAfter ''
    echo "test" | bcachefs unlock -k session ${PRIMARY}
  '';

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
