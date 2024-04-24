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

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows =
        "nixpkgs"; # Use system packages list where available
    };

    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nypkgs, nixpkgs, home-manager, ... } @ inputs:
    let
      myHosts = [
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
        hostsDir = ./hosts;
        usersDir = ./users;
      };
    in
    {
      # foldl' is "reduce" where { } is the accumulator and myHosts is the array to reduce on.
      nixosConfigurations = builtins.foldl'
        (acc: nixConfig:
          acc // {
            "${nixConfig.name}" = nixpkgs.lib.nixosSystem
              {
                modules = [./hosts/_common/configuration.nix ./hosts/${nixConfig.name}/configuration.nix ];
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
        myHosts;
    };
}
