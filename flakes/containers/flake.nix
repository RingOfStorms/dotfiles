{
  description = "Extra-container parent flake. Provides NixOS module + shared lib for child container flakes.";

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { extra-container, nixpkgs, ... }:
    {
      # Hosts import this to get extra-container installed and ready.
      # Usage: inputs.containers.nixosModules.default
      nixosModules.default =
        { ... }:
        {
          imports = [ extra-container.nixosModules.default ];
          programs.extra-container.enable = true;
        };

      # Child container flakes use these to build containers with a shared
      # extra-container version, keeping the host binary and container lib in sync.
      lib = extra-container.lib;
    };
}
