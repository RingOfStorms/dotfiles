{
  inputs = {
    home-manager.url = "github:rycee/home-manager/release-24.11";
    ragenix.url = "github:yaxitech/ragenix";

    ros_neovim.url = "git+https://git.joshuabell.xyz/nvim";
    ringofstorms-stormd.url = "git+ssh://git.joshuabell.xyz:3032/stormd";
    # ros_neovim.url = "path:/home/josh/projects/stormd";

    hyprland.url = "github:hyprwm/Hyprland";
    cosmic.url = "github:lilyinstarlight/nixos-cosmic";
  };

  outputs =
    {
      ros-neovim,
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
          let
            custom_config_key = "ringofstorms_common";
          in
          {
            options = {
            };

            imports = [
              ./boot/grub.nix
            ];

            config = {
              specialArgs = {
                inherit custom_config_key;
              };
            };
          };
      };
    };
}
