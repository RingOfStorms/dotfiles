# PLACEHOLDER -- Regenerate on the actual machine with:
#   nixos-generate-config --show-hardware-config > hardware-configuration.nix
#
# This template includes the expected structure for an NVIDIA desktop system.
# Replace filesystem UUIDs, device paths, and kernel modules with actual values.
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

  # Storage / USB modules needed in initrd to find the root filesystem
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];

  # Early KMS for NVIDIA (provides console resolution before full driver loads)
  boot.initrd.kernelModules = [ "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" ];

  boot.kernelModules = [ "kvm-intel" ]; # or "kvm-amd" depending on CPU
  boot.extraModulePackages = [ ];

  # ── Filesystems ──────────────────────────────────────────────────────────
  # TODO: Replace with actual UUIDs/labels from `nixos-generate-config`
  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXROOT"; # TODO: replace
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/NIXBOOT"; # TODO: replace
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ]; # TODO: add swap partition or swapfile if desired

  # ── General ──────────────────────────────────────────────────────────────
  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # TODO: set to intel or amd depending on your CPU
  # hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  # hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
