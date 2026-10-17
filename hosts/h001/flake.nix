{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    home-manager.url = "github:rycee/home-manager/release-26.05";

    # nixpkgs-unstable.url = "github:wrvsrx/nixpkgs/fix-open-webui";
    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
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
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.podman
          inputs.common.nixosModules.tailnet
          inputs.common.nixosModules.timezone_chi
          inputs.common.nixosModules.tty_caps_esc
          inputs.common.nixosModules.zsh

          inputs.beszel.nixosModules.agent
          ({
            beszelAgent = {
              token = "20208198-87c2-4bd1-ab09-b97c3b9c6a6e";
              extraFilesystems = "sda__Media";
            };
          })

          inputs.containers.nixosModules.default
          ./floating-containers.nix
          ./hardware-configuration.nix
          ./mods
          # Atuin history sync: the local primary user logs into the shared `josh`
          # atuin account (the account comes from the secret, not the local user).
          inputs.common.nixosModules.atuin
          ({
            ringofstorms.atuin = {
              enable = true;
              autologin = {
                enable = true;
                user = constants.host.primaryUser;
                secretFile = "/var/lib/secrets_manager_hydrated/atuin-key-josh_2026-03-15";
                afterUnits = [ "sec-secrets-ready.service" ];
              };
            };
          })

          (import ./sec-agent.nix { inherit inputs constants; })
          ./nginx.nix
          ./autofs.nix

          # Host-specific config
          (
            { pkgs, ... }:
            {
              users.users.root = {
                shell = pkgs.zsh;
                openssh.authorizedKeys.keys = [ fleet.global.sshPubKey ];
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
