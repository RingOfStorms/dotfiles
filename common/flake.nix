{
  inputs = {
    home-manager.url = "github:rycee/home-manager/release-24.11";
    ragenix.url = "github:yaxitech/ragenix";

    hyprland.url = "github:hyprwm/Hyprland";
    cosmic.url = "github:lilyinstarlight/nixos-cosmic";
  };

  outputs =
    {
      home-manager,
      ...
    }:
    {
      nixosModules = {
        default =
          {
            config,
            lib,
            ...
          }:
          {
            imports = [
              home-manager.nixosModules.home-manager
              ./options.nix
              ./general
              ./home_manager
              ./boot
              ./users
              ./programs
            ];
          };
      };
    };
}
