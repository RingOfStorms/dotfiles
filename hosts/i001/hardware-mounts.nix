{ ... }:
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

  # PRIMARY unencrypt
  # TODO how to auto unencrypt with options...
  # - USB key
  # - TPM

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
