{
  pkgs,
  settings,
  ...
}:
{
  imports = [
    # Users this machine has
    (settings.usersDir + "/root/configuration.nix")
    (settings.usersDir + "/luser/configuration.nix")

    # (settings.hostsDir + "/h002/nixserver.nix")
  ];

  # My custom modules
  mods = {
    boot_grub = true;
    shell_common.enable = true;
    de_gnome_xorg.enable = true;
    audio_pulse.enable = true;
    neovim.enable = true;
    tty_caps_esc.enable = true;
    docker.enable = true;
    stormd.enable = true;
    nebula.enable = true;
    ssh.enable = true;
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

  environment.systemPackages = with pkgs; [ nvtopPackages.full ];
}
