{
  pkgs,
  config,
  ...
}:
{
  # machine specific configuration
  # ==============================
  hardware.enableAllFirmware = true;
  hardware.enableRedistributableFirmware = true;
  # Connectivity
  networking.networkmanager.enable = true;
  hardware.bluetooth.enable = true;
  # networking.networkmanager.unmanaged = [ "interface-name:wlp*" ]; # Mark wireless as unmanaged
  environment.shellAliases = {
    wifi = "nmtui";
  };

  # Realtek wireless module support
  # Ensure the rtl8192 module is loaded (RTL8190 typically uses rtl8192 driver)

  # boot.extraModulePackages = [ config.boot.kernelPackages.rtl8192eu ];
  boot.kernelModules = [
    "rtl8192ce"
    "rtl8192c_common"
    "rtlwifi"
    "mac80211"
  ];
  # Install network management tools
  environment.systemPackages = with pkgs; [
    pciutils
    wirelesstools
    iw
    networkmanager
    nvtopPackages.full
  ];
}
