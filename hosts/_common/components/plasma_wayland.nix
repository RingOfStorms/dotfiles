{ pkgs, ... }:
{
  services.xserver = {
    enable = true;
    displayManager.gdm = {
      enable = true;
      autoSuspend = false;
      wayland = true;
    };
    displayManager.defaultSession = "plasma";
    displayManager.sddm.wayland.enable = true;
    desktopManager.plasma6 = {
      enable = true;
    };
  };
  environment.systemPackages = with pkgs; [
    xclip
  ];
}


