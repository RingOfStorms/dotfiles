{
  description = "whoami: example podman floating service";
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
  outputs =
    { nixpkgs, ... }:
    let
      boxes = import ../../lib.nix;
      forAll = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      packages = forAll (system: {
        default = boxes.mkPodmanService {
          pkgs = nixpkgs.legacyPackages.${system};
          service = import ./service.nix;
        };
      });
    };
}
