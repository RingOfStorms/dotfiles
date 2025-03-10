{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    deploy-rs.url = "github:serokell/deploy-rs";

    mod_common.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_common";
    mod_common.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      deploy-rs,
      ...
    }@inputs:
    let
      configuration_name = "o001";
      lib = nixpkgs.lib;
    in
    {
      deploy = {
        sshUser = "root";
        sshOpts = [
          "-i"
          "/run/agenix/nix2oracle"
        ];
        nodes.${configuration_name} = {
          hostname = "64.181.210.7";
          targetPlatform = "aarch64-linux";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.${configuration_name};
          };
        };
      };

      nixosConfigurations = {
        nixos = self.nixosConfigurations.${configuration_name};
        "${configuration_name}" =
          let
            auto_modules = builtins.concatMap (
              input:
              lib.optionals
                (builtins.hasAttr "nixosModules" input && builtins.hasAttr "default" input.nixosModules)
                [
                  input.nixosModules.default
                ]
            ) (builtins.attrValues inputs);
          in
          (lib.nixosSystem {
            system = "aarch64-linux";
            modules = [
              ./configuration.nix
              ./hardware-configuration.nix
              ./nginx.nix
              ../../../components/nix/tailscale.nix
              (
                { pkgs, ... }:
                {
                  users.users.root.openssh.authorizedKeys.keys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG90Gg6dV3yhZ5+X40vICbeBwV9rfD39/8l9QSqluTw8 nix2oracle"
                  ];
                  components = {
                    # NOTE we manually onboard this machine since it has no secrets uploaded to it
                    tailscale.useSecretsAuth = false;
                  };
                  mods = {
                    common = {
                      disableRemoteBuildsOnLio = true;
                      systemName = configuration_name;
                      allowUnfree = true;
                      primaryUser = "luser";
                      docker = true;
                      users = {
                        luser = {
                          extraGroups = [
                            "wheel"
                            "networkmanager"
                          ];
                          isNormalUser = true;
                          openssh.authorizedKeys.keys = [
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG90Gg6dV3yhZ5+X40vICbeBwV9rfD39/8l9QSqluTw8 nix2oracle"
                          ];
                        };
                      };
                    };
                  };
                }
              )
            ] ++ auto_modules;
            specialArgs = {
              inherit inputs;
            };
          });
      };
    };
}
