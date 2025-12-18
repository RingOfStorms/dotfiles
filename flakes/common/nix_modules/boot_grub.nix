{
  lib,
  ...
}:

{
  boot.loader.grub = {
    enable = true;
    device = lib.mkDefault "/dev/sda";
  };
}
