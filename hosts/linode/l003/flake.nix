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
      configuration_name = "l003";
      lib = nixpkgs.lib;
    in
    {
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
            modules = [
              ./configuration.nix
              ./hardware-configuration.nix
              ./linode.nix
              (
                { pkgs, ... }:
                {
                  users.users.root.openssh.authorizedKeys.keys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFLBVLiPbhVG+riNNpkvXnNtOioByV3CQwtY9gu8pstp nix2l002"
                  ];
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
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFLBVLiPbhVG+riNNpkvXnNtOioByV3CQwtY9gu8pstp nix2l002"
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

      deploy = {
        sshUser = "root";
        sshOpts = [
          "-i"
          "/run/agenix/nix2l002"
        ];
        nodes.${configuration_name} = {
          hostname = "172.234.26.141";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.${configuration_name};
          };
        };
      };
    };
}
