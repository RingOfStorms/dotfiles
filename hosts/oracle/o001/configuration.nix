{ config, lib, pkgs, ... }:

{
  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  system.stateVersion = "25.05"; # Did you read the comment?
  # boot.supportedFilesystems = [ "zfs" ];


  boot.kernelParams = [ "net.ifnames=0" ];
  networking.useDHCP = false;  # deprecated flag, set to false until removed
  networking = {
    defaultGateway = "10.0.0.1";
    nameservers = [ "9.9.9.9" ];  
    interfaces.eth0 = {
      ipAddress = "149.130.211.142";
      prefixLength = 24;
    };
  };

  networking.firewall.enable = true;
  networking.firewall.allowPing = true;
}
