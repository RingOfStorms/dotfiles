{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    home-manager.url = "github:rycee/home-manager/release-26.05";

    # nixpkgs-unstable.url = "github:wrvsrx/nixpkgs/fix-open-webui";
    open-webui-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    litellm-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    trilium-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    oauth2-proxy-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    zitadel-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    beszel-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    forgejo-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    n8n-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    dawarich-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    immich-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    paperless-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # Pinned to the 2026-02-27 unstable rev that the matrix container ran on
    # for months. A later unstable bump (during the 26.05 migration) shipped
    # mautrix-signal 26.02.1-pre, whose libsignal SEGFAULTs in
    # signal_encrypt_message (Element->Signal sends crash, receives hit
    # libsignal null-pointer errors). Keep this pin until a newer unstable rev
    # ships a working mautrix-signal/libsignal; then bump deliberately + test.
    #
    # TODO (staged bump): unstable e72e4f299401a3689d4b3d5fc6496b11db7064eb has
    # mautrix-gmessages 26.05, mautrix-signal 26.07, libsignal-ffi 0.97.2,
    # synapse 1.157.2, element-web 1.12.24, postgresql_17 17.10. Bumping to it
    # would let BOTH overlays in containers/matrix.nix be deleted — but it also
    # re-tests the signal/libsignal combination that segfaulted above, so do it
    # when you can verify Element->Signal sends by hand. Until then the
    # gmessages 26.05 overlay backports just the SMS duplicate-message fix.
    matrix-nixpkgs.url = "github:nixos/nixpkgs/dd9b079222d43e1943b6ebd802f04fd959dc8e61";

    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
    secrets_manager.url = "git+ssh://git@git.joshuabell.xyz:3032/ringofstorms/secrets_manager.git";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    puzzles.url = "git+ssh://git@git.joshuabell.xyz:3032/ringofstorms/puzzles.git";

    # pkm — personal knowledge system. Supplies both the NixOS module and the
    # packages (server with the frontend embedded, and the PowerSync service
    # built from source). See hosts/h001/containers/pkm.nix.
    pkm.url = "git+ssh://git@git.joshuabell.xyz:3032/ringofstorms/pkm.git";

    nixarr.url = "github:rasmus-kirk/nixarr";
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
        # secrets_manager server (hosts/h001/mods/sec.nix).

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
          inputs.common.nixosModules.rage

          inputs.beszel.nixosModules.agent
          ({
            beszelAgent = {
              token = "20208198-87c2-4bd1-ab09-b97c3b9c6a6e";
              extraFilesystems = "sda__Media";
            };
          })

          inputs.puzzles.nixosModules.default
          inputs.nixarr.nixosModules.default
          ./hardware-configuration.nix
          ./mods
          (import ./sec-agent.nix { inherit inputs constants; })
          ./nginx.nix
          ./containers
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
