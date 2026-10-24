{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    home-manager.url = "github:rycee/home-manager/release-26.05";

    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # impermanence.url = "path:../../flakes/impermanence";
    impermanence.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";
    secrets_manager.url = "git+https://git.joshuabell.xyz/ringofstorms/secrets_manager.git";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    # Read-only dashboard; path ref ships the working tree.
    fleet-edge.url = "path:../../flakes/fleet-edge";
    # Inventory source for fleet-edge (built into the closure).
    containers.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=containers";
    fleet-agent.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/fleet-agent";
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
        # `mkpasswd -m yescrypt`
        authMethod = "hashedPassword";
        authValue = "$y$j9T$yH09E.BFlkAyHQxSfKsdV.$vD85biEJFQaiT02YiArOHDd/Ghk55NkHx1yNrRtd255";
        mutableUsers = false;
        extraGroups = [ "wheel" ];

        nixosModules = [
          inputs.impermanence.nixosModules.default
          ({
            ringofstorms.impermanence = {
              enable = true;
              disk = {
                boot = "/dev/disk/by-uuid/DA82-16A8";
                primary = "/dev/disk/by-uuid/0d6e4079-e367-03eb-d37c-00722f5891d2";
                # 4G on the eMMC, re-encrypted with a random key every boot.
                swap = "/dev/disk/by-partuuid/36d1b20f-0aad-46a3-b83f-d246ec250ed8";
              };
              # Encrypted root, unlocked at boot by the bcachefs USB key stick
              # (utilities/nixos-install-disko/usb_key.md), which stays plugged
              # in so the router comes back unattended after a power cut.
              # Without the stick it falls back to a console passphrase prompt.
              encrypted = true;
              usbKey = true;
              # Password of the encrypted USB key stick. It's in the repo and the
              # store; it only protects a stick that is lost on its own.
              usbKeyPassword = "Obsessive-Remindful-Cosigner6";
            };
          })
          (import ./impermanence.nix {
            inherit primaryUser;
            impermanence = inputs.impermanence;
          })

          inputs.ros_neovim.nixosModules.default

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
          ./fleet-edge.nix
          ./firewall.nix
        ]
        ++ lib.optionals constants.network.routerEnable [
          ./mods
          # Needs the bunny key, which sec-agent only fetches in router mode.
          ./private-zone.nix
          ./wildcard-cert.nix
          # Fleet oauth2-proxy; uses the wildcard above for its sign-in host.
          ./oauth2-proxy.nix
        ]
        ++ [
          # Host-specific config
          (
            { pkgs, ... }:
            {
              # Bench ports are DHCP clients; router mode enables DHCP only on
              # the WAN and configures the two tagged gateway interfaces.
              networking.useDHCP = !constants.network.routerEnable;
              security.sudo.wheelNeedsPassword = false;
              environment.systemPackages = with pkgs; [
                tcpdump
                dig
                ethtool
              ];
            }
          )
        ];
      };
    };
}
