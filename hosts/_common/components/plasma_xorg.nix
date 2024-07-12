{ pkgs, ... }:
{
  services.xserver = {
    enable = true;
    displayManager.gdm = {
      enable = true;
      autoSuspend = false;
      wayland = false;
    };
    displayManager.defaultSession = "plasmax11";
    desktopManager.plasma6 = {
      enable = true;
    };
  };
  environment.systemPackages = with pkgs; [
    xclip
  ];
}

