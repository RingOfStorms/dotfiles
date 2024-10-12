{
  description = "My systems flake";

  inputs = {
    # Host flake pinning
    lio_nixpkgs.url = "github:nixos/nixpkgs/nixos-24.05";
    lio_home-manager = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "lio_nixpkgs";
    };

    joe_nixpkgs.url = "github:nixos/nixpkgs/nixos-24.05";
    joe_home-manager = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "joe_nixpkgs";
    };

    h002_nixpkgs.url = "github:nixos/nixpkgs/nixos-24.05";
    h002_home-manager = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "h002_nixpkgs";
    };

    gpdPocket3_nixpkgs.url = "github:nixos/nixpkgs/nixos-24.05";
    gpdPocket3_home-manager = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "gpdPocket3_nixpkgs";
    };

    nixpkgs_stable.url = "github:nixos/nixpkgs/nixos-24.05";
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
      url = "git+https://git.joshuabell.xyz/nvim";
    };

    cosmic = {
      url = "github:lilyinstarlight/nixos-cosmic";
    };
  };

  outputs =
    {
      self,
      nypkgs,
      cosmic,
      lio_nixpkgs,
      lio_home-manager,
      joe_nixpkgs,
      joe_home-manager,
      gpdPocket3_nixpkgs,
      gpdPocket3_home-manager,
      h002_nixpkgs,
      h002_home-manager,
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
          name = "lio";
          opts = {
            system = "x86_64-linux";
          };
          settings = {
            inherit user;
            nixpkgs = lio_nixpkgs;
            home-manager = lio_home-manager;
            allowUnfree = true;
          };
        }
        {
          name = "joe";
          opts = {
            system = "x86_64-linux";
          };
          settings = {
            inherit user;
            nixpkgs = joe_nixpkgs;
            home-manager = joe_home-manager;
            allowUnfree = true;
          };
        }
        {
          name = "gpdPocket3";
          opts = {
            system = "x86_64-linux";
          };
          settings = {
            inherit user;
            nixpkgs = gpdPocket3_nixpkgs;
            home-manager = gpdPocket3_home-manager;
            allowUnfree = true;
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
            nixpkgs = h002_nixpkgs;
            home-manager = h002_home-manager;
            allowUnfree = true;
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
            let
              settings = nixConfig.settings;
              lib = settings.nixpkgs.lib;
              ylib = nypkgs.legacyPackages.${nixConfig.opts.system}.lib;
            in
            (lib.nixosSystem {
              modules =
                [
                  cosmic.nixosModules.default
                  settings.home-manager.nixosModules.home-manager
                ]
                ++ ylib.umport {
                  path = lib.fileset.maybeMissing ./modules;
                  recursive = true;
                }
                ++ [
                  ./hosts/configuration.nix
                ];
              specialArgs = inputs // {
                inherit ylib;
                settings =
                  directories
                  // settings
                  // {
                    system = nixConfig.opts // {
                      hostname = nixConfig.name;
                    };
                  };
              };
            })
            // nixConfig.opts;
        }
      ) { } myHosts;
    };
}
