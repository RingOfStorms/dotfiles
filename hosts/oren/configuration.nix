{
  ...
}:
{
  system.stateVersion = "24.11"; # Did you read the comment?

  networking.networkmanager.enable = true;
  environment.shellAliases = {
    wifi = "nmtui";
  };
  boot.kernelModules = [
    "rtl8192ce"
    "rtl8192c_common"
    "rtlwifi"
    "mac80211"
  ];
}
