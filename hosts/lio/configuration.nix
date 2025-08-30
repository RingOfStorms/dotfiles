{
  ...
}:
{
  hardware.enableAllFirmware = true;

  # Connectivity
  networking.networkmanager.enable = true;
  hardware.bluetooth.enable = true;

  # System76
  hardware.system76.enableAll = true;
  # https://discourse.nixos.org/t/very-high-fan-noises-on-nixos-using-a-system76-thelio/23875/10
  # Fixes insane jet speed fan noise
  services.power-profiles-daemon.enable = false;

  system.stateVersion = "23.11";
}
