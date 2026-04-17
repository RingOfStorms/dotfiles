{
  description = "Extra-container parent flake. Provides NixOS module for hosts.";

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
  };

  outputs =
    { extra-container, ... }:
    {
      # Hosts import this to get extra-container installed and ready.
      # Usage: inputs.containers.nixosModules.default
      nixosModules.default =
        { ... }:
        {
          imports = [ extra-container.nixosModules.default ];
          programs.extra-container.enable = true;
          boot.enableContainers = true;
        };
    };
}
