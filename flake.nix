{
  description = "My systems flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-23.11-small";
    # home-manager = { };
  };

  outputs = { self, nixpkgs, ... } @ args:
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
        };
        usersDir = ./users;
        systemsDir = ./systems;
        commonDir = ./_common;
        flakeDir = ./.;
      };
    in
    {
      nixosConfigurations.${settings.system.hostname} = nixosSystem {
        system = settings.system.architecture;
        modules = [ ./systems/_common/configuration.nix ./systems/${settings.system.hostname}/configuration.nix ];
        specialArgs = args // { inherit settings; };
      };
      # homeConfigurations = { };
    };
}
