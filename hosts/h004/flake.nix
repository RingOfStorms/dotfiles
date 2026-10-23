{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    home-manager.url = "github:rycee/home-manager/release-26.05";

    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # impermanence_mod.url = "path:../../flakes/impermanence";
    impermanence_mod.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";
    secrets_manager.url = "git+https://git.joshuabell.xyz/ringofstorms/secrets_manager.git";
    fleet-agent.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/fleet-agent";

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
                swap = "/dev/disk/by-partuuid/cd3735f2-eee9-4d03-9ae3-464a6f84941f";
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
          inputs.common.nixosModules.ssh_root
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.no_sleep
          inputs.common.nixosModules.timezone_chi
          inputs.common.nixosModules.tty_caps_esc
          inputs.common.nixosModules.zsh
          inputs.common.nixosModules.tailnet

          # Atuin history sync. Logs the local user (luser) into the shared
          # `josh` atuin account: the account comes from the secret's
          # contents, not from the local username.
          inputs.common.nixosModules.atuin
          ({
            ringofstorms.atuin = {
              enable = true;
              autologin = {
                enable = true;
                user = primaryUser;
                secretFile = "/var/lib/secrets_manager_hydrated/atuin-key-josh_2026-03-15";
                afterUnits = [ "sec-secrets-ready.service" ];
              };
            };
          })

          (import ./sec-agent.nix { inherit inputs constants; })
          ../ups-shutdown-receiver.nix

          ./hardware-configuration.nix
          ./firewall.nix
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
          ./backup-receiver.nix
          ({
            ringofstorms.fleetAgent.extraFilesystems = [ "/data" ];
          })
        ]
        ++ [
          # Host-specific config
          ({
            networking.networkmanager.enable = true;
            security.sudo.wheelNeedsPassword = false;
          })
        ];
      };
    };
}
