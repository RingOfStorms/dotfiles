{ pkgs, ... }:
{
  # https://www.linode.com/docs/guides/install-nixos-on-linode/#configure-nixos
  boot.kernelParams = [ "console=ttyS0,19200n8" ];
  boot.loader.grub.extraConfig = ''
    serial --speed=19200 --unit=0 --word=8 --parity=no --stop=1;
    terminal_input serial;
    terminal_output serial
  '';

  boot.loader.grub.forceInstall = true;
  boot.loader.grub.device = "nodev";
  boot.loader.timeout = 10;

  # TODO disable after first startup with ssh keys
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
    settings.PasswordAuthentication = false;
  };

  networking.usePredictableInterfaceNames = false;
  networking.useDHCP = false; # Disable DHCP globally as we will not need it.
  # required for ssh?
  networking.interfaces.eth0.useDHCP = true;

  environment.systemPackages = with pkgs; [
    inetutils
    mtr
    sysstat
    gitMinimal
    vim
    nano
  ];

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFLBVLiPbhVG+riNNpkvXnNtOioByV3CQwtY9gu8pstp nix2l002"
  ];
}
