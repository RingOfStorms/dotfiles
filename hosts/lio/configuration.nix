{
  ...
}:
{
  # opening this port for dev purposes
  networking.firewall.allowedTCPPorts = [
    5173 # Vite
  ];

  # machine specific configuration
  # ==============================
  hardware.enableAllFirmware = true;
  # Connectivity
  networking.networkmanager.enable = true;
  hardware.bluetooth.enable = true;
  environment.shellAliases = {
    wifi = "nmtui";
  };

  # System76
  hardware.system76.enableAll = true;

  system.stateVersion = "23.11";
}
