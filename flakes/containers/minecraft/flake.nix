{
  description = "Minecraft extra-container: Velocity proxy + 2 Paper servers via nix-minecraft";

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    nix-minecraft.url = "github:Infinidoge/nix-minecraft";
    # Use 25.11 to match extra-container's nixpkgs pin.
    # extra-container's eval-config.nix has a minimal module set with dummy
    # options that are incompatible with nixpkgs-unstable (see issue #40).
    # nix-minecraft server packages (Paper, Velocity, etc.) are fetched via
    # its overlay and are independent of the nixpkgs version here.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
  };

  outputs =
    {
      extra-container,
      nix-minecraft,
      nixpkgs,
      ...
    }:
    extra-container.lib.eachSupportedSystem (system: {
      packages.default = extra-container.lib.buildContainers {
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
