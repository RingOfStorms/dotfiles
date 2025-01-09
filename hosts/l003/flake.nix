{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";

    mod_common.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_common";
    mod_common.inputs.nixpkgs.follows = "nixpkgs";
    mod_common.inputs.ragenix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
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
              ./common.nix
              (
                { pkgs, ... }:
                {
                  users.users.root.openssh.authorizedKeys.keys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJN2nsLmAlF6zj5dEBkNSJaqcCya+aB6I0imY8Q5Ew0S nix2lio"
                  ];
                  mods = {
                    common = {
                      flakeLocationOverride = "/home/luser/.config/nixos-config";
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
    };
}
