{
  pkgs,
  lib,
  config,
  ...
}:
{
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
  # Allow emulation of aarch64-linux binaries for cross compiling
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # ── Steam ──────────────────────────────────────────────────────────────────
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
    gamescopeSession.enable = true;
    protontricks.enable = true;
    extraCompatPackages = with pkgs; [
      proton-ge-bin
    ];
  };
}
