{ pkgs, ... }:
{
  # home.packages = [ pkgs.spotifyd ];
# TODO revisit this isn't working for me yet...
  services.spotifyd.enable =true;
}


