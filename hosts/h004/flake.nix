{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    home-manager.url = "github:rycee/home-manager/release-26.05";

    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    impermanence_mod.url = "path:../../flakes/impermanence";
    # impermanence_mod.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";
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
                boot = "/dev/disk/by-uuid/3CB6-E638";
                primary = "/dev/disk/by-uuid/de5f5f6f-4f15-482e-9ef1-98b0c52845f6";
                # Swap is declared below with a random key per boot; the
                # module's swap entry would be plaintext.
                swap = null;
              };
              # Encrypted root, unlocked at boot by the bcachefs USB key stick
              # (utilities/nixos-install-disko/usb_key.md), which stays plugged
              # in so the NAS comes back unattended after a power cut. Without
              # the stick it falls back to a console passphrase prompt.
              encrypted = true;
              usbKey = true;
              # Password of the encrypted USB key stick. It's in the repo and the
              # store; it only protects a stick that is lost on its own.
              usbKeyPassword = "Emphatic3-Dart-Chemicals";
            };
          })
          # 8G swap partition (nvme0n1p2), re-encrypted with a fresh random key
          # every boot so nothing from the encrypted root lands on disk in
          # plaintext. No hibernation on this host. by-partuuid stays stable
          # because random encryption rewrites the partition's contents.
          ({
            swapDevices = [
              {
                device = "/dev/disk/by-partuuid/cd3735f2-eee9-4d03-9ae3-464a6f84941f";
                randomEncryption.enable = true;
              }
            ];
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
