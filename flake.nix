{
  description = "My systems flake";

  inputs = {
    nixpkgs_unstable.url = "github:nixos/nixpkgs/master";
    nixpkgs_stable.url = "github:nixos/nixpkgs/nixos-24.05";

    nixpkgs_joe.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager_joe = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs_joe";
    };
    nixpkgs_h002.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager_h002 = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs_h002";
    };
    nixpkgs_gpdPocket3.url = "github:nixos/nixpkgs/nixos-24.05";
    home-manager_gdpPocket3 = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs_gpdPocket3";
    };

    # Nix utility methods
    nypkgs = {
      url = "github:yunfachi/nypkgs";
      inputs.nixpkgs.follows = "nixpkgs_stable";
    };

    # Secrets management for nix
    ragenix = {
      url = "github:yaxitech/ragenix";
      inputs.nixpkgs.follows = "nixpkgs_stable";
    };

    ringofstorms-nvim = {
      url = "github:RingOfStorms/nvim";
      # inputs.nixpkgs.follows = "nixpkgs_unstable";
    };
  };

  outputs =
    {
      self,
      nypkgs,
      nixpkgs_joe,
      home-manager_joe,
      nixpkgs_gpdPocket3,
      home-manager_gdpPocket3,
      nixpkgs_h002,
      home-manager_h002,
      ...
    }@inputs:
    let
      user = {
        username = "josh";
        git = {
          email = "ringofstorms@gmail.com";
          name = "RingOfStorms (Joshua Bell)";
        };
      };
      myHosts = [
        {
          name = "joe";
          opts = {
            system = "x86_64-linux";
          };
          settings = {
            inherit user;
            nixpkgs = nixpkgs_joe;
            home-manager = home-manager_joe;
          };
        }
        {
          name = "gpdPocket3";
          opts = {
            system = "x86_64-linux";
          };
          settings = {
            inherit user;
            nixpkgs = nixpkgs_gpdPocket3;
            home-manager = home-manager_gdpPocket3;
          };
        }
        {
          name = "h002";
          opts = {
            system = "x86_64-linux";
          };
          settings = {
            user = {
              username = "luser";
              git = {
                email = "ringofstorms@gmail.com";
                name = "RingOfStorms (Joshua Bell)";
              };
            };
            nixpkgs = nixpkgs_h002;
            home-manager = home-manager_h002;
          };
        }
      ];

      directories = {
        flakeDir = ./.;
        publicsDir = ./publics;
        secretsDir = ./secrets;
        hostsDir = ./hosts;
        usersDir = ./users;
      };
    in
    {
      # foldl' is "reduce" where { } is the accumulator and myHosts is the array to reduce on.
      nixosConfigurations = builtins.foldl' (
        acc: nixConfig:
        acc
        // {
          "${nixConfig.name}" =
            nixConfig.settings.nixpkgs.lib.nixosSystem {
              # module = nixConfig.overrides.modules or [...]
              modules = [ ./hosts/_common/configuration.nix ];
              specialArgs = inputs // {
                ylib = nypkgs.legacyPackages.${nixConfig.opts.system}.lib;
                settings =
                  directories
                  // nixConfig.settings
                  // {
                    system = nixConfig.opts // {
                      hostname = nixConfig.name;
                    };
                  };
              };
            }
            // nixConfig.opts;
        }
      ) { } myHosts;
    };
}
