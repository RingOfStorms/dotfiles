# Hardware-specific config for GPD Pocket 3
# Supplements nixos-hardware.nixosModules.gpd-pocket-3 (imported in flake.nix)
#
# Filesystem mounts are handled in hardware-mounts.nix (bcachefs + impermanence).
# This file only covers CPU/GPU/initrd hardware detection.
{
  config,
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "thunderbolt"
    "nvme"
    "usbhid"
    "usb_storage"
    "uas"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [
    "kvm-intel"
    "btusb"
    "hid-nintendo"  # Nintendo Switch Pro Controller support (BT + USB)
    "uinput"        # Virtual input devices for Steam controller remapping
  ];
  boot.extraModulePackages = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
