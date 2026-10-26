{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    home-manager.url = "github:rycee/home-manager/release-26.05";

    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # impermanence.url = "path:../../flakes/impermanence";
    impermanence.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";
    secrets_manager.url = "git+https://git.joshuabell.xyz/ringofstorms/secrets_manager.git";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    # containers.url = "path:../../containers";
    containers.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=containers";
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
        # Atuin autologin into the shared `josh` account (fleet.nix enableAtuin).
        enableAtuin = true;
        # Same login as the old h003 install (`mkpasswd -m yescrypt`).
        authMethod = "hashedPassword";
        authValue = "$y$j9T$Q7YjLw1PfGhkSeNp4e.xL1$G5iXBPQqmaSFMfRdYnat1uRfRi18Y/AeglETGfGUS9A";
        mutableUsers = false;
        extraGroups = [
          "wheel"
          "networkmanager"
        ];

        nixosModules = [
          inputs.impermanence.nixosModules.default
          ({
            ringofstorms.impermanence = {
              enable = true;
              disk = {
                boot = "/dev/disk/by-uuid/5746-956B";
                primary = "/dev/disk/by-uuid/0d6e4079-e367-03eb-d37c-00722f5891d2";
                swap = "/dev/disk/by-partuuid/0c94f55e-4a24-4258-9d00-9a7c86b2cc2d";
              };
              # Encrypted root, unlocked at boot by the bcachefs USB key stick
              # (utilities/nixos-install-disko/usb_key.md), which stays plugged
              # in so the host comes back unattended after a power cut. Without
              # the stick it falls back to a console passphrase prompt.
              encrypted = true;
              usbKey = true;
              # Password of the encrypted USB key stick. It's in the repo and the
              # store; it only protects a stick that is lost on its own.
              usbKeyPassword = "Plank7-Mothball-Pretended";
            };
          })
          (import ./impermanence.nix {
            inherit primaryUser;
            impermanence = inputs.impermanence;
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

          (import ./sec-agent.nix { inherit inputs constants; })

          ./hardware-configuration.nix

          inputs.containers.nixosModules.default
          ./containers.nix
          ./firewall.nix
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
