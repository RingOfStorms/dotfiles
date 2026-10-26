{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    home-manager.url = "github:rycee/home-manager/release-26.05";

    # nixpkgs-unstable.url = "github:wrvsrx/nixpkgs/fix-open-webui";
    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    secrets_manager.url = "git+ssh://git@git.joshuabell.xyz:3032/ringofstorms/secrets_manager.git";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    # Floating containers host module (containers/). Path ref for local testing:
    # containers.url = "path:../../containers";
    containers.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=containers";
  };

  outputs =
    { ... }@inputs:
    let
      fleet = import ../fleet.nix;
      constants = import ./_constants.nix { inherit fleet; };
    in
    {
      nixosConfigurations.${constants.host.name} = fleet.mkHost {
        inherit inputs constants;
        # Atuin autologin into the shared `josh` account (fleet.nix enableAtuin).
        enableAtuin = true;
        # h001 reads its rendered values from sec-agent and runs the
        # secrets_manager server (containers/sec; floating container).

        # `mkpasswd -m yescrypt.
        authMethod = "hashedPassword";
        authValue = "$y$j9T$bM8vOOgaq5pmNKxyCH4FI0$jutaQjd3g9uVvTa2yecQihBCaH9PjOiYyt.HbLHnSh3";
        mutableUsers = false;

        nixosModules = [
          inputs.ros_neovim.nixosModules.default
          ({ ringofstorms-nvim.includeAllRuntimeDependencies = true; })

          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.tmux
          inputs.common.nixosModules.boot_systemd
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.ssh_root
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.podman
          inputs.common.nixosModules.tailnet
          inputs.common.nixosModules.timezone_chi
          inputs.common.nixosModules.tty_caps_esc
          inputs.common.nixosModules.zsh

          inputs.containers.nixosModules.default
          ./floating-containers.nix
          ({
            ringofstorms.fleetAgent.extraFilesystems = [ "/mnt/media" ];
          })
          ./hardware-configuration.nix
          ./mods

          (import ./sec-agent.nix { inherit inputs constants; })
          ./nginx.nix
          ../_shared_assets/utilities/ups-shutdown-receiver.nix
          ./firewall.nix
          ./autofs.nix

          # Host-specific config
          (
            { pkgs, ... }:
            {
              users.users.root = {
                shell = pkgs.zsh;
              };
              environment.systemPackages = with pkgs; [
                lua
                sqlite
                ttyd
                rclone
              ];
              environment.shellAliases = {
                mva = "/home/luser/projects/mva/target/release/mva";
              };
            }
          )
        ];
      };
    };
}
