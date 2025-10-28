{
  pkgs,
  ...
}:
{
  services.xserver.xkb.options = "caps:escape";
  console = {
    earlySetup = true;
    packages = with pkgs; [ terminus_font ];
    # use xkb.options in tty. (caps -> escape)
    useXkbConfig = true;
  };
}
