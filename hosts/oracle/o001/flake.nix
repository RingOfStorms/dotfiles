{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";
    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    # Use relative to get current version for testing
    # common.url = "path:../../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # secrets-bao.url = "path:../../../flakes/secrets-bao";
    secrets-bao.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets-bao";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
  };

  outputs =
    { ... }@inputs:
    let
      fleet = import ../../fleet.nix;
      constants = import ./_constants.nix;
      overlayIp = constants.host.overlayIp;
    in
    {
      nixosConfigurations.${constants.host.name} = fleet.mkHost {
        inherit inputs constants;
        secretsRole = "machines-hightrust";
        authMethod = "cloudUser";

        nixosModules = [
          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.docker
          inputs.common.nixosModules.tailnet
          ({ ringofstorms.tailnet.omitCaptivePortal = false; })
          inputs.common.nixosModules.zsh

          inputs.beszel.nixosModules.agent
          ({
            beszelAgent = {
              listen = "${overlayIp}:45876";
              token = "f8a54c41-486b-487a-a78d-a087385c317b";
            };
          })

          inputs.ros_neovim.nixosModules.default

          ./configuration.nix
          ./hardware-configuration.nix
          ./nginx.nix
          ./containers/vaultwarden.nix
          ./mods/postgresql.nix
          ./mods/atuin.nix

          # Host-specific packages
          (
            { pkgs, ... }:
            {
              environment.systemPackages = with pkgs; [ vaultwarden ];
            }
          )
        ];
      };
    };
}
