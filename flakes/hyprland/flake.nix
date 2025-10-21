{
  inputs = {
    ragenix.url = "github:yaxitech/ragenix";
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
