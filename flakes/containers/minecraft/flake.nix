{
  description = "Minecraft extra-container: Velocity proxy + 2 Paper servers via nix-minecraft";

  inputs = {
    # Inherit extra-container from parent -- single pin for host binary + container lib
    containers.url = "path:..";
    nix-minecraft.url = "github:Infinidoge/nix-minecraft";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      containers,
      nix-minecraft,
      nixpkgs,
      ...
    }:
    containers.lib.eachSupportedSystem (system: {
      packages.default = containers.lib.buildContainers {
        inherit system nixpkgs;

        config.containers.minecraft = {
          # No privateNetwork -- services bind directly on host interfaces.
          # Not ephemeral -- state persists at /var/lib/nixos-containers/minecraft/
          specialArgs = { inherit nix-minecraft; };
          config = import ./container.nix;
        };
      };
    });
}
