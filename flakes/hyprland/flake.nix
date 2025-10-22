{
  inputs = {
    hyprland.url = "github:hyprwm/Hyprland";
  };

  outputs =
    {
      hyprland,
      ...
    }:
    {
      nixosModules = {
        default =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          {
            imports = [
              hyprland.nixosModules.default
              ./hyprland.nix
            ];
            config = {
              _module.args = {
                inherit hyprland;
                hyprlandPkgs = import hyprland.inputs.nixpkgs {
                  system = pkgs.stdenv.hostPlatform.system;
                  config = config.nixpkgs.config or { };
                };
              };
            };
          };
      };
    };
}
