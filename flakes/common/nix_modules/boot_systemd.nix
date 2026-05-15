{
  ...
}:
{
  boot.loader = {
    systemd-boot = {
      enable = true;
      # `max` instead of `keep` so systemd-boot picks the largest mode
      # the firmware advertises that the kernel can keep using through
      # the simpledrm → real-KMS handover. With `keep`, the firmware
      # text mode persists into early kernel and is then swapped, which
      # blanks the screen at the exact moment Plymouth is trying to
      # attach — one of the contributors to the "boot drops to logs"
      # race documented in the plymouth module.
      consoleMode = "max";
      configurationLimit = 10;
    };
    timeout = 5;
    efi = {
      canTouchEfiVariables = true;
    };
  };
}
