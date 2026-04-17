{
  ...
}:
{
  boot.loader = {
    systemd-boot = {
      enable = true;
      consoleMode = "keep";
      configurationLimit = 10;
    };
    timeout = 5;
    efi = {
      canTouchEfiVariables = true;
    };
  };
}
