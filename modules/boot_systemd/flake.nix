{
  inputs = {
  };

  outputs =
    {
      self,
      ...
    }:
    {
      nixosModules = {
        default =
          {
            config,
            lib,
            ...
          }:
          {
            config = {
              # Use the systemd-boot EFI boot loader.
              boot.loader = {
                systemd-boot = {
                  enable = true;
                  consoleMode = "keep";
                };
                timeout = 5;
                efi = {
                  canTouchEfiVariables = true;
                };
              };
            };
          };
      };
    };
}
