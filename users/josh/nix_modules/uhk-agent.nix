{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [ uhk-agent uhk-udev-rules ];
  
  services.udev.packages = [ pkgs.uhk-udev-rules ];
}
