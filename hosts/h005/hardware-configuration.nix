# Generated on the bench by `nixos-generate-config --no-filesystems` (MeLE Quieter DL,
# Intel N150, 233G eMMC `mmc-Y1Y256_0xc15902ff`). Filesystems come from
# ringofstorms.impermanence. NICs: 2× Intel i226-V (igc): enp1s0 = WAN, enp2s0 = TRUNK
# (labelled on the case).
{
  config,
  lib,
  modulesPath,
  ...
}:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "usb_storage"
    "usbhid"
    "uas"
    "sd_mod"
    "sdhci_pci"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
