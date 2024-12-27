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
    de_cosmic.enable = true;
    neovim.enable = true;
    tty_caps_esc.enable = true;
    docker.enable = true;
    fonts.enable = true;
    stormd.enable = true;
    nebula.enable = true;
    ssh.enable = true; # new
    # rustdesk.enable = true;
  };

  # Use the systemd-boot EFI boot loader.
  system.stateVersion = "24.11"; # Did you read the comment?
}
