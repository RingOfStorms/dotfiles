{
  description = "My systems flake";

  inputs = {
    # Nix utility methods
    nypkgs = {
      url = "github:yunfachi/nypkgs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secrets management for nix
    ragenix = {
      url = "github:yaxitech/ragenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Pinned nix version
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-23.11";

    # TODO
    # home-manager = { };
  };

  outputs = { self, nypkgs, nixpkgs, ... } @ inputs:
    let
      nixConfigs = [
        {
          name = "gpdPocket3";
          opts = {
            system = "x86_64-linux";
          };
          settings = {
            user = {
              username = "josh";
              git = {
                email = "ringofstorms@gmail.com";
                name = "RingOfStorms (Joshua Bell)";
              };
            };
          };
        }
        {
          name = "joe";
          opts = {
            system = "x86_64-linux";
          };
          settings = {
            user = {
              username = "josh";
              git = {
                email = "ringofstorms@gmail.com";
                name = "RingOfStorms (Joshua Bell)";
              };
            };
          };
        }
      ];

      directories = {
        flakeDir = ./.;
        publicsDir = ./publics;
        secretsDir = ./secrets;
        systemsDir = ./systems;
        usersDir = ./users;
      };
    in
    {
      nixosConfigurations = builtins.foldl'
        (acc: nixConfig:
          acc // {
            "${nixConfig.name}" = nixpkgs.lib.nixosSystem
              {
                modules = [ ./systems/_common/configuration.nix ./systems/${nixConfig.name}/configuration.nix ];
                specialArgs = inputs // {
                  ylib = nypkgs.legacyPackages.${nixConfig.opts.system}.lib;
                  settings = directories // nixConfig.settings // {
                    system = nixConfig.opts // {
                      hostname = nixConfig.name;
                    };
                  };
                };
              } // nixConfig.opts;
          })
        { }
        nixConfigs;

      # nixosConfigurations = {
      #   gpdPocket3 = nixosSystem {
      #     system = "x86_64-linux";
      #     modules = [ ./systems/_common/configuration.nix ./systems/gpdPocket3/configuration.nix ];
      #     specialArgs = inputs // {
      #       inherit ylib;
      #       settings = directories // {
      #         system = {
      #           # TODO remove these probably not needed anymore with per machine specified here
      #           hostname = "gpdPocket3";
      #           architecture = "x86_64-linux";
      #         };
      #       };
      #     };
      #   };
      #   joe = nixosSystem {
      #     system = "x86_64-linux";
      #     modules = [ ./systems/_common/configuration.nix ./systems/joe/configuration.nix ];
      #     specialArgs = inputs // {
      #       inherit ylib;
      #       settings = directories // {
      #         system = {
      #           # TODO remove these probably not needed anymore with per machine specified here
      #           hostname = "joe";
      #           architecture = "x86_64-linux";
      #         };
      #       };
      #     };
      #   };
      # };
      # homeConfigurations = { };
    };
}
