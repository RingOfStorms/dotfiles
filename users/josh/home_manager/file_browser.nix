{ pkgs, ... }:
{
  home.packages = with pkgs; [ nautilus qimgv ];
}
