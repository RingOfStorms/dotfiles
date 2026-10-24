# QEMU/KVM guest. Filesystems come from disko-config.nix (real disk or
# vm-disko); `nixos-rebuild build-vm` replaces them with its own.
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  boot.initrd.availableKernelModules = [
    "ahci"
    "xhci_pci"
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "sr_mod"
  ];
}
