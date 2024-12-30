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
    boot_systemd.enable = true; # new
    shell_common.enable = true; # new
    # de_cosmic.enable = true; # TODO
    audio.enable = true;
    de_gnome_xorg.enable = true;
    # de_gnome_wayland.enable = true;
    neovim.enable = true; # new
    tty_caps_esc.enable = true; # new
    docker.enable = true; # new
    fonts.enable = true; # new
    ssh.enable = true; # new
    stormd.enable = true; # new
    nebula.enable = true; # new
    rustdesk.enable = true; # TODO
    saber.enable = true; # removed
  };

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
