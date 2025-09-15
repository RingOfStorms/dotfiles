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

  system.stateVersion = "23.11";

  services = {
    # https://discourse.nixos.org/t/very-high-fan-noises-on-nixos-using-a-system76-thelio/23875/10
    # Fixes insane jet speed fan noise
    power-profiles-daemon.enable = false;
    tlp = {
      enable = true;
      # settings = {
      #   CPU_BOOST_ON_AC = 1;
      #   CPU_BOOST_ON_BAT = 0;
      #   CPU_SCALING_GOVERNOR_ON_AC = "performance";
      #   CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
      #   STOP_CHARGE_THRESH_BAT0 = 95;
      # };
    };
  };
}
