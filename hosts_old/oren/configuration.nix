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
    de_cosmic.enable = true; # new
    neovim.enable = true; # new
    tty_caps_esc.enable = true; # new
    docker.enable = true; # new
    fonts.enable = true; # new
    stormd.enable = true; # new
    nebula.enable = true; # new
    ssh.enable = true; # new
    # rustdesk.enable = true;
  };

  # Use the systemd-boot EFI boot loader.
  system.stateVersion = "24.11"; # Did you read the comment?
}
