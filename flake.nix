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
      nixosSystem = nixpkgs.lib.nixosSystem;
      mkMerge = nixpkgs.lib.mkMerge;

      sett = {
        user = {
          username = "josh";
          git = {
            email = "ringofstorms@gmail.com";
            name = "RingOfStorms (Joshua Bell)";
          };
        };
        flakeDir = ./.;
        publicsDir = ./publics;
        secretsDir = ./secrets;
        systemsDir = ./systems;
        usersDir = ./users;
      };

      ypkgs = nypkgs.legacyPackages.x86_64-linux;
      ylib = ypkgs.lib;
    in
    {
      nixosConfigurations = {
        gpdPocket3 = nixosSystem {
          system = "x86_64-linux";
          modules = [ ./systems/_common/configuration.nix ./systems/gpdPocket3/configuration.nix ];
          specialArgs = inputs // {
            inherit ylib;
            settings = sett // {
              system = {
                # TODO remove these probably not needed anymore with per machine specified here
                hostname = "gpdPocket3";
                architecture = "x86_64-linux";
                timeZone = "America/Chicago"; # TODO roaming?
                defaultLocale = "en_US.UTF-8";
              };
            };
          };
        };
        joe = nixosSystem {
          system = "x86_64-linux";
          modules = [ ./systems/_common/configuration.nix ./systems/joe/configuration.nix ];
          specialArgs = inputs // {
            inherit ylib;
            settings = sett // {
              system = {
                # TODO remove these probably not needed anymore with per machine specified here
                hostname = "joe";
                architecture = "x86_64-linux";
                # TODO remove?
                timeZone = "America/Chicago";
                defaultLocale = "en_US.UTF-8";
              };
            };
          };
        };
      };
      # homeConfigurations = { };
    };
}
