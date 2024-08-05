{
  pkgs,
  settings,
  ...
}:
{
  imports = [
    # Common components this machine uses
    (settings.hostsDir + "/_common/components/neovim.nix")
    (settings.hostsDir + "/_common/components/ssh.nix")
    (settings.hostsDir + "/_common/components/caps_to_escape_in_tty.nix")
    (settings.hostsDir + "/_common/components/audio.nix")
    (settings.hostsDir + "/_common/components/home_manager.nix")
    (settings.hostsDir + "/_common/components/docker.nix")
    (settings.hostsDir + "/_common/components/nebula.nix")
    # Users this machine has
    (settings.usersDir + "/root/configuration.nix")
    (settings.usersDir + "/luser/configuration.nix")

    # (settings.hostsDir + "/h002/nixserver.nix")
  ];

  boot.loader.grub = {
    enable = true;
    device = "/dev/sdb";
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
