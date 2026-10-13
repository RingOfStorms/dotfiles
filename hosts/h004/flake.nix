{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    home-manager.url = "github:rycee/home-manager/release-26.05";

    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # impermanence_mod.url = "path:../../flakes/impermanence";
    impermanence_mod.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";
    secrets_manager.url = "git+https://git.joshuabell.xyz/ringofstorms/secrets_manager.git";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    nixarr.url = "github:rasmus-kirk/nixarr";
  };

  outputs =
    { ... }@inputs:
    let
      fleet = import ../fleet.nix;
      constants = import ./_constants.nix;
      lib = inputs.nixpkgs.lib;
      primaryUser = constants.host.primaryUser;
      overlayIp = constants.host.overlayIp;
    in
    {
      nixosConfigurations.${constants.host.name} = fleet.mkHost {
        inherit inputs constants;
        # Same login as h002 (`mkpasswd -m yescrypt`).
        authMethod = "hashedPassword";
        authValue = "$y$j9T$iM1fEKZQH9NGQd39OTUJI.$uxPdQ7EDf4wANcFs7QDSjDC8tV5ZW4cAuNXBdqibSX4";
        mutableUsers = false;
        extraGroups = [
          "wheel"
          "networkmanager"
        ];

        nixosModules = [
          inputs.impermanence_mod.nixosModules.default
          ({
            ringofstorms.impermanence = {
              enable = true;
              disk = {
                # TODO: fill in from `lsblk -o name,uuid` after disko on the
                # Inland TN320 NVMe (utilities/nixos-install-disko/readme.md).
                boot = "/dev/disk/by-uuid/TODO-ESP";
                primary = "/dev/disk/by-uuid/TODO-BCACHEFS";
                swap = "/dev/disk/by-uuid/TODO-SWAP";
              };
              # Headless NAS that must come back after a power cut: unencrypted
              # root (the data pool is unencrypted anyway).
              encrypted = false;
            };
          })
          (import ./impermanence.nix {
            inherit primaryUser;
            impermanence_mod = inputs.impermanence_mod;
          })

          inputs.ros_neovim.nixosModules.default
          ({ ringofstorms-nvim.includeAllRuntimeDependencies = true; })

          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.tmux
          inputs.common.nixosModules.boot_systemd
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.no_sleep
          inputs.common.nixosModules.timezone_chi
          inputs.common.nixosModules.tty_caps_esc
          inputs.common.nixosModules.zsh
          inputs.common.nixosModules.rage
          inputs.common.nixosModules.tailnet

          (import ./sec-agent.nix { inherit inputs constants; })

          ./hardware-configuration.nix
          ./data-pool.nix

          # nixarr module only for its shared media uids/gids (nfs-data-users-nixarr.nix).
          inputs.nixarr.nixosModules.default
        ]
        # NFS export + media dir perms only once the pool is enabled; on the
        # bench there is no data.mount for nfs-server to require, and tmpfiles
        # would create media dirs on the wiped root.
        ++ lib.optionals constants.dataPool.enable [
          ./nfs-data.nix
          ./nfs-data-users-nixarr.nix
        ]
        ++ lib.optionals (overlayIp != null) [
          inputs.beszel.nixosModules.agent
          ({
            beszelAgent = {
              listen = "${overlayIp}:45876";
              token = "3a0fe19c-f7a9-4506-b76b-61ce2612cfbd";
            };
            services.beszel.agent.environment = lib.optionalAttrs constants.dataPool.enable {
              EXTRA_FILESYSTEMS = "/data__Data";
            };
          })
        ]
        ++ [
          # Host-specific config
          ({
            networking.networkmanager.enable = true;
            security.sudo.wheelNeedsPassword = false;
            users.users.root.openssh.authorizedKeys.keys = [
              fleet.global.sshPubKey
            ];
          })
        ];
      };
    };
}
