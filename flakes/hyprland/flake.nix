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
              nix.settings = {
                substituters = [
                  "https://hyprland.cachix.org"
                ];
                trusted-substituters = [
                  "https://hyprland.cachix.org"
                ];
                trusted-public-keys = [
                  "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
                ];
              };
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
