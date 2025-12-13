{ ... }:
let
  BOOT = "/dev/disk/by-uuid/6E40-637E";
  PRIMARY = "/dev/disk/by-uuid/ec589da0-4deb-44a3-abcb-9a7016d84519";

  USB_KEY = "/dev/disk/by-uuid/9985-EBD1";
in
{
  # BOOT
  fileSystems."/boot" = {
    device = BOOT;
    fsType = "vfat";
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
  fileSystems."/.swap" = {
    device = PRIMARY;
    fsType = "bcachefs";
    options = [
      "X-mount.subdir=@swap"
      "noatime"
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
}
