{ pkgs, ... }:
{
  # I want this globally even for root so doing it outside of home manager
  services.xserver.xkb.options = "caps:escape";
  console = {
    earlySetup = true;
    packages = with pkgs; [ terminus_font ];
    useXkbConfig = true; # use xkb.options in tty. (caps -> escape)
  };
}
