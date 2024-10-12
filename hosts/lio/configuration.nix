{
  settings,
  ...
}:
{
  imports = [
    # Users this machine has
    (settings.usersDir + "/root/configuration.nix")
    (settings.usersDir + "/josh/configuration.nix")
  ];

  # My custom modules
  mods = {
    boot_systemd.enable = true;
    shell_common.enable = true;
    de_cosmic.enable = true;
    neovim.enable = true;
    tty_caps_esc.enable = true;
    docker.enable = true;
    fonts.enable = true;
  #  nebula.enable = true;
    ssh.enable = true;
    # stormd.enable = true; # TODO figure out why this is failing
  };

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
}
