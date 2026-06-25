# Hardware configuration for an Oracle Cloud Ampere (aarch64) VM.
#
# Does NOT declare fileSystems/swapDevices: disko (disko.nix, enableConfig
# = true) emits the runtime bcachefs mounts (/, /boot, /nix, /persist,
# /.snapshots, swap).
#
# Oracle Ampere VMs are virtio/qemu guests with UEFI boot. Use GRUB
# installed as removable to the ESP fallback path (/EFI/BOOT/BOOTAA64.EFI)
# WITHOUT writing EFI NVRAM vars (the kexec installer can't, and Oracle's
# firmware boots the fallback path anyway). This is the EXACT config that
# the working o001 box uses, confirmed booting on Oracle Ampere.
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
  # Force nvme early in initrd (matches the working o001 box).
  boot.initrd.kernelModules = [ "nvme" ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # bcachefs support in initrd + running system.
  boot.supportedFilesystems = [ "bcachefs" ];

  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
