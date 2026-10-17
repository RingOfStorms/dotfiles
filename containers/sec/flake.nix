{
  description = "sec: secrets_manager server as a floating container";

  # Managed with the `containers` CLI (see ../README.md).

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    # Host-side extra-container eval must stay on 25.11 (issue #40) ...
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    # ... the guest runs the nixpkgs rev h001 runs today.
    guestpkgs.url = "github:nixos/nixpkgs/6fcc160353f63555b560f25588925133c8f61f2a";
    # Locked to the rev h001 runs today (72a1e3b); bump with `nix flake update secrets_manager`.
    secrets_manager.url = "git+ssh://git@git.joshuabell.xyz:3032/ringofstorms/secrets_manager.git";
  };

  outputs =
    {
      extra-container,
      nixpkgs,
      guestpkgs,
      secrets_manager,
      ...
    }:
    let
      containersLib = import ../lib.nix;
    in
    extra-container.lib.eachSupportedSystem (system: {
      packages.default = extra-container.lib.buildContainers {
        inherit system nixpkgs;
        config = containersLib.mkNixosContainer {
          service = import ./service.nix;
          config = import ./container.nix;
          guestNixpkgs = guestpkgs;
          # Host network; idmapped persist (ext4).
          privateNetwork = false;
          specialArgs = { inherit secrets_manager; };
        };
      };
    });
}
