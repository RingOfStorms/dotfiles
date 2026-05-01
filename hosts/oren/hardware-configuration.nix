# Hardware configuration for oren (Framework 16, AMD).
#
# Filesystem mounts and swap are handled by the impermanence module
# (bcachefs subvolume layout: @root / @nix / @snapshots / @persist).
# See flakes/impermanence/bcachefs-impermanence.nix.
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
    "nvme"
    "xhci_pci"
    "thunderbolt"
    "usbhid"
    "uas"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # Allow emulation of aarch64-linux binaries for cross compiling
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  hardware.enableAllFirmware = true;
  hardware.bluetooth.enable = true;
  hardware.enableRedistributableFirmware = true;
  hardware.inputmodule.enable = true;
  networking.networkmanager.enable = true;
}
