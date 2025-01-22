{ pkgs, ... }:
{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  boot.supportedFilesystems = [ "zfs" ];
  boot.kernelParams = [ "net.ifnames=0" ];

  networking.useDHCP = false;  # deprecated flag, set to false until removed
  networking = {
    defaultGateway = "10.0.0.1";
    nameservers = [ "9.9.9.9" ];  
    interfaces.eth0 = {
      ipAddress = throw "set your own";
      prefixLength = 24;
    };
  };

  # TODO disable after first startup with ssh keys
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
    settings.PasswordAuthentication = false;
  };

  # networking.usePredictableInterfaceNames = false;
  # networking.useDHCP = false; # Disable DHCP globally as we will not need it.
  # required for ssh?
  # networking.interfaces.eth0.useDHCP = true;

  environment.systemPackages = with pkgs; [
    inetutils
    mtr
    sysstat
    gitMinimal
    vim
    nano
  ];

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG90Gg6dV3yhZ5+X40vICbeBwV9rfD39/8l9QSqluTw8 nix2oracle"
  ];
}
