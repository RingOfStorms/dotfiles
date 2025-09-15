{
  pkgs,
  lib,
  config,
  ...
}:
{
  system.stateVersion = "24.11"; # Did you read the comment?
  environment.systemPackages = with pkgs; [
    # [Laptop] Battery status
    acpi
    bluez # bluetoothctl command
  ];
  hardware.enableAllFirmware = true;
  hardware.bluetooth.enable = true;
  networking.networkmanager.enable = true;
  environment.shellAliases = {
    wifi = "nmtui";
    battery = "acpi";
  };
  boot.kernelModules = [
    "rtl8192ce"
    "rtl8192c_common"
    "rtlwifi"
    "mac80211"
  ];

  services.tlp.enable = true;
}
