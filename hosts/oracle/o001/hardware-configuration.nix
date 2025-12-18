{
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/92B6-AAE1";
    fsType = "vfat";
  };
  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "xen_blkfront"
  ];
  boot.initrd.kernelModules = [ "nvme" ];
  fileSystems."/" = {
    device = "/dev/sda3";
    fsType = "xfs";
  };
  swapDevices = [ { device = "/dev/sda2"; } ];
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  # My oracle machine is too tiny and boot partition too small to accept a new kernel, locking in at this version...
  boot.kernelPackages = pkgs.linuxPackages_6_12;
}
