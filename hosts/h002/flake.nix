{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # secrets-bao.url = "path:../../flakes/secrets-bao";
    secrets-bao.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets-bao";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    nixarr.url = "github:rasmus-kirk/nixarr";
  };

  outputs =
    { ... }@inputs:
    let
      fleet = import ../fleet.nix;
      constants = import ./_constants.nix;
      overlayIp = constants.host.overlayIp;
    in
    {
      nixosConfigurations.${constants.host.name} = fleet.mkHost {
        inherit inputs constants;
        secretsRole = "machines-hightrust";
        authMethod = "initialHashedPassword";
        authValue = "$y$j9T$v1QhXiZMRY1pFkPmkLkdp0$451GvQt.XFU2qCAi4EQNd1BEqjM/CH6awU8gjcULps6";
        extraGroups = [ "wheel" "networkmanager" ];

        nixosModules = [
          inputs.ros_neovim.nixosModules.default
          ({ ringofstorms-nvim.includeAllRuntimeDependencies = true; })

          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.tmux
          inputs.common.nixosModules.boot_grub
          ({ lib, ... }: {
            boot.loader.grub.device = lib.mkForce "/dev/disk/by-id/ata-KINGSTON_SV300S37A120G_50026B773C00F8F4";
          })
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.no_sleep
          inputs.common.nixosModules.timezone_chi
          inputs.common.nixosModules.tty_caps_esc
          inputs.common.nixosModules.zsh
          inputs.common.nixosModules.tailnet

          inputs.beszel.nixosModules.agent
          ({
            beszelAgent = {
              listen = "${overlayIp}:45876";
              token = "11714da6-fd2e-436a-8b83-e0e07ba33a95";
            };
            services.beszel.agent.environment = {
              EXTRA_FILESYSTEMS = "/data__Data";
            };
          })

          inputs.nixarr.nixosModules.default
          ./hardware-configuration.nix
          ./nfs-data.nix
          ./nfs-data-users-nixarr.nix

          # Host-specific config
          ({
            networking.networkmanager.enable = true;
            users.users.root.openssh.authorizedKeys.keys = [
              fleet.global.sshPubKey
            ];
          })
        ];
      };
    };
}
