{
  description = "My systems flake";

  inputs = {
    # Nix utility methods
    nypkgs = {
      url = "github:yunfachi/nypkgs/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Pinned nix version
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-23.11-small";

    # TODO
    # home-manager = { };
  };

  outputs = { self, nypkgs, nixpkgs, ... } @ args:
    let
      nixosSystem = nixpkgs.lib.nixosSystem;
      mkMerge = nixpkgs.lib.mkMerge;
      settings = {
        system = {
          hostname = "gpdPocket3";
          architecture = "x86_64-linux";
          timeZone = "America/Chicago";
          defaultLocale = "en_US.UTF-8";
        };
        user = {
          username = "josh";
          git = {
            email = "ringofstorms@gmail.com";
            name = "RingOfStorms (Joshua Bell)";
          };
        };
        usersDir = ./users;
        systemsDir = ./systems;
        commonDir = ./_common;
        flakeDir = ./.;
      };

      ypkgs = nypkgs.legacyPackages.${settings.system.architecture};
      ylib = ypkgs.lib;
    in
    {
      nixosConfigurations.${settings.system.hostname} = nixosSystem {
        system = settings.system.architecture;
        modules = [ ./systems/_common/configuration.nix ./systems/${settings.system.hostname}/configuration.nix ];
        specialArgs = args // { inherit settings; inherit ylib; };
      };
      # homeConfigurations = { };
    };
}
