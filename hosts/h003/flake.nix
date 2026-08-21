{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    home-manager.url = "github:rycee/home-manager/release-26.05";

    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # sec-agent replaces secrets-bao on this host.
    secrets_manager.url = "git+https://git.joshuabell.xyz/ringofstorms/secrets_manager.git";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
    # containers.url = "path:../../flakes/containers";
    containers.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/containers";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
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

        # `mkpasswd -m yescrypt` hash
        authMethod = "hashedPassword";
        authValue = "$y$j9T$Q7YjLw1PfGhkSeNp4e.xL1$G5iXBPQqmaSFMfRdYnat1uRfRi18Y/AeglETGfGUS9A";
        mutableUsers = false;

        nixosModules = [
          inputs.ros_neovim.nixosModules.default

          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.boot_systemd
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.podman
          inputs.common.nixosModules.tailnet
          inputs.common.nixosModules.timezone_chi
          inputs.common.nixosModules.tty_caps_esc
          inputs.common.nixosModules.zsh
          inputs.common.nixosModules.rage

          (import ./sec-agent.nix { inherit inputs constants; })

          inputs.containers.nixosModules.default
          inputs.beszel.nixosModules.agent
          ({
            beszelAgent = {
              listen = "${overlayIp}:45876";
              token = "f8a54c41-486b-487a-a78d-a087385c317b";
            };
          })

          ./hardware-configuration.nix
          ./mods
          ./containers.nix

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
                tcpdump
                dig
                picocom # serial console for the Omada SG3210X-M2 switch
              ];

              # `omada` — connect to the SG3210X-M2 serial console.
              # 38400 8N1; --omap delbs fixes Backspace (keyboard sends DEL 0x7f,
              # switch wants BS 0x08). Exit picocom with Ctrl-A then Ctrl-X.
              # Needs sudo: /dev/ttyACM0 is root:dialout.
              environment.shellAliases.omada =
                "sudo ${pkgs.picocom}/bin/picocom -b 38400 --omap delbs /dev/ttyACM0";
            }
          )
        ];
      };
    };
}
