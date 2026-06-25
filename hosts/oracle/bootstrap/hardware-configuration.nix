# Hardware configuration for an Oracle Cloud Ampere (aarch64) VM.
#
# Deliberately does NOT declare fileSystems/swapDevices: the
# bcachefs-impermanence module (ringofstorms.impermanence) owns all the
# boot-drive mounts (/, /boot, /nix, /persist, /.snapshots, swap).
#
# Oracle Ampere VMs are virtio/qemu guests with UEFI boot. GRUB installs
# as removable (Oracle's UEFI looks for the fallback bootloader path).
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };

  # virtio for the disk/net, nvme seen on the Oracle block device path.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "virtio_net"
    "nvme"
    "ahci"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # bcachefs support in initrd + system (the impermanence module only sets
  # this when encrypted = true; we run unencrypted, so set it here).
  boot.supportedFilesystems = [ "bcachefs" ];

  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
