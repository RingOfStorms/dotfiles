{
  description = "Minecraft floating container: Velocity proxy + 2 Paper servers via nix-minecraft";

  # Managed with the `boxes` CLI (see ../README.md and ./README.md).
  # By hand on the host:
  #   nix run .  -- create --start          deploy or update
  #   sudo systemctl stop container@minecraft   blocking stop
  #   nix run .  -- destroy                  remove (data in /srv/containers/minecraft stays)

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    nix-minecraft.url = "github:Infinidoge/nix-minecraft";
    # Must stay on 25.11: extra-container's minimal eval-config breaks on
    # nixpkgs-unstable (extra-container issue #40). nix-minecraft server
    # packages come from its overlay, independent of this nixpkgs.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
  };

  outputs =
    {
      extra-container,
      nix-minecraft,
      nixpkgs,
      ...
    }:
    let
      boxes = import ../lib.nix;
    in
    extra-container.lib.eachSupportedSystem (system: {
      packages.default = extra-container.lib.buildContainers {
        inherit system nixpkgs;
        config = boxes.mkNixosContainer {
          service = import ./service.nix;
          specialArgs = { inherit nix-minecraft; };
          config = import ./container.nix;
        };
      };
    });
}
