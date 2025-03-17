{
  inputs = {
    home-manager.url = "github:rycee/home-manager/release-24.11";
    ragenix.url = "github:yaxitech/ragenix";

    hyprland.url = "github:hyprwm/Hyprland";
    cosmic.url = "github:lilyinstarlight/nixos-cosmic";
  };

  outputs =
    {
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
          let
            ccfg = import ./config.nix;
            cfg_path = "${ccfg.custom_config_key}";
            cfg = config.${cfg_path};
          in
          {
            imports = [
              ./options.nix
              ./boot
              ./users
              ./general
            ];
          };
      };
    };
}
