{
  description = "hello-podman: test podman service serving the nginx splash page";
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
  outputs =
    { nixpkgs, ... }:
    let
      containersLib = import ../lib.nix;
      forAll = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      packages = forAll (system: {
        default = containersLib.mkPodmanService {
          pkgs = nixpkgs.legacyPackages.${system};
          service = import ./service.nix;
        };
      });
    };
}
