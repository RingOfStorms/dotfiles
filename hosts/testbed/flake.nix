# testbed — a VM of the general fleet config (see readme.md).
#
#   nix run ./hosts/testbed#vm            fast VM (nixos-rebuild build-vm style)
#   nix run ./hosts/testbed#vm-desktop    same with the Plasma desktop
#   nix run ./hosts/testbed#vm-disko      VM on the real disko layout
#
# Like every host it pins `common`/`de_plasma` via flake.lock; to run it on the
# working tree instead: hosts/_shared_assets/utilities/local-host.sh testbed build-vm
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    home-manager.url = "github:rycee/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # de_plasma.url = "path:../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";

    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    { self, ... }@inputs:
    let
      fleet = import ../fleet.nix;
      constants = import ./_constants.nix;
      primaryUser = constants.host.primaryUser;

      mkTestbed =
        { desktop }:
        fleet.mkHost {
          inherit inputs constants;
          # Test-only password; this VM is never deployed or networked
          # beyond QEMU's user-mode NAT. (The old public `password1` hash is
          # rejected by fleet.mkHost, pentest C2.)
          authMethod = "initialPassword";
          authValue = "testbed";

          nixosModules = [
            inputs.disko.nixosModules.disko
            ./disko-config.nix
            ./hardware-configuration.nix

            inputs.ros_neovim.nixosModules.default

            inputs.common.nixosModules.essentials
            inputs.common.nixosModules.git
            inputs.common.nixosModules.tmux
            inputs.common.nixosModules.boot_systemd
            inputs.common.nixosModules.hardening
            inputs.common.nixosModules.nix_options
            inputs.common.nixosModules.podman
            inputs.common.nixosModules.timezone_auto
            inputs.common.nixosModules.zsh

            (
              { pkgs, ... }:
              {
                users.users.${primaryUser}.shell = pkgs.zsh;
                users.users.root.initialPassword = "testbed";
                security.sudo.wheelNeedsPassword = false;
                networking.networkmanager.enable = true;

                # build-vm / vm-disko sizing.
                virtualisation.vmVariant.virtualisation = {
                  memorySize = 4096;
                  cores = 4;
                  diskSize = 16384;
                  graphics = desktop;
                  forwardPorts = [
                    {
                      from = "host";
                      host.port = 2222;
                      guest.port = 22;
                    }
                  ];
                };
                virtualisation.vmVariantWithDisko.virtualisation = {
                  memorySize = 4096;
                  cores = 4;
                  graphics = desktop;
                };
                # Hardening disables password SSH; for the VM allow it.
                services.openssh.settings.PasswordAuthentication = pkgs.lib.mkForce true;

                environment.systemPackages = with pkgs; [
                  cowsay
                  lolcat
                ];
              }
            )
          ]
          ++ inputs.nixpkgs.lib.optionals desktop [
            inputs.de_plasma.nixosModules.default
            {
              ringofstorms.dePlasma = {
                enable = true;
                sddm.autologinUser = primaryUser;
              };
            }
          ];
        };
    in
    {
      nixosConfigurations = {
        testbed = mkTestbed { desktop = false; };
        testbed-desktop = mkTestbed { desktop = true; };
      };

      packages.x86_64-linux = {
        vm = self.nixosConfigurations.testbed.config.system.build.vm;
        vm-desktop = self.nixosConfigurations.testbed-desktop.config.system.build.vm;
        vm-disko = self.nixosConfigurations.testbed.config.system.build.vmWithDisko;
        default = self.packages.x86_64-linux.vm;
      };
    };
}
