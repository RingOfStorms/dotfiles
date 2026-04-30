{
  # Self-contained flake for the bifrost-models regen script. Lives in its
  # own subdir (rather than in the repo-root flake) so non-h001 machines
  # don't pull a Go toolchain into their dev shell. Activate with
  # `cd scripts/bifrost_models && nix develop` (or via direnv — see .envrc).
  description = "bifrost-models — regenerate hosts/h001/mods/bifrost_models.nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        bifrost-models = pkgs.callPackage ./default.nix { };
      in
      {
        packages = {
          inherit bifrost-models;
          default = bifrost-models;
        };

        # `nix run` from this dir invokes the binary directly.
        apps.default = {
          type = "app";
          program = "${bifrost-models}/bin/bifrost-models";
        };

        # `nix develop` / direnv puts the binary on PATH plus go tooling
        # in case you want to iterate on the source.
        devShells.default = pkgs.mkShell {
          packages = [ bifrost-models pkgs.go pkgs.gopls ];
        };
      });
}
