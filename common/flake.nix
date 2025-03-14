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
      ros_neovim,
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
              ./boot/grub.nix
              ./boot/systemd.nix
              ./users/users.nix
            ];
            options.${cfg_path} = {
              systemName = lib.mkOption {
                type = lib.types.str;
                description = "The name of the system.";
              };
            };
            config = {
              # // TODO ADD Nix helper stuff rest of it.
            };
          };
      };
    };
}
