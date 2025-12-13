{ pkgs, ... }:
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
  fileSystems."/nix" = {
    device = PRIMARY;
    fsType = "bcachefs";
    options = [
      "X-mount.subdir=@nix"
      "relatime"
    ];
  };
  fileSystems."/.snapshots" = {
    device = PRIMARY;
    fsType = "bcachefs";
    options = [
      "X-mount.subdir=@root"
      "relatime"
    ];
  };
  fileSystems."/.swap" = {
    device = PRIMARY;
    fsType = "bcachefs";
    options = [
      "X-mount.subdir=@swap"
      "noatime"
    ];
  };
  # (optional) for preservation/impermanence
  fileSystems."/persist" = {
    device = PRIMARY;
    fsType = "bcachefs";
    options = [
      "X-mount.subdir=@persist"
    ];
  };

  # SWAP
  swapDevices = [
    {
      device = "/.swap/swapfile";
      size = 8 * 1024; # Creates an 8GB swap file
    }
  ];

  # PRIMARY unencrypt
  # TODO how to auto unencrypt with options...
  # - USB key
  # - TPM
  boot.initrd.availableKernelModules = [ "bcachefs" ];
  boot.initrd.extraUtilsCommands = ''
    copy_bin_and_libs ${pkgs.bcachefs-tools}/bin/bcachefs
  '';

  boot.initrd.preDeviceCommands = ''
    ${pkgs.bcachefs-tools}/bin/bcachefs unlock /dev/disk/by-uuid/XXXX
  '';

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

  # Reset root
  # TODO
  # boot.initrd.systemd.services.rollback-root = {
  #   description = "Rollback Root Filesystem to Blank Snapshot";
  #   wantedBy = [ "initrd.target" ];
  #   after = [ "persist.mount" ];
  #   requires = [ "persist.mount" ];
  #   before = [ "sysroot.mount" ];
  #   unitConfig.DefaultDependencies = false;
  #   serviceConfig = {
  #     Type = "oneshot";
  #     ExecStart = "/bin/sh -c 'bcachefs subvolume delete /persist/@root; bcachefs subvolume snapshot /persist/@root-blank /persist/@root'";
  #   };
  # };
}
