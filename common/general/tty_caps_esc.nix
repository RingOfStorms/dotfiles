{
  lib,
  pkgs,
  ...
}:
with lib;
{
  config = {
    services.xserver.xkb.options = "caps:escape";
    console = {
      earlySetup = true;
      packages = with pkgs; [ terminus_font ];
      useXkbConfig = true; # use xkb.options in tty. (caps -> escape)
    };
  };
}
