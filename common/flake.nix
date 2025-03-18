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
      ragenix,
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
              ragenix.nixosModules.age
              ./_home_manager
              ./options.nix
              ./general
              ./boot
              ./desktop_environment
              ./users
              ./programs
              ./secrets
            ];
            config = {
              _module.args = {
                inherit ragenix;
              };
            };
          };
        containers = {
          librechat = import ./_containers/librechat.nix;
        };
      };
      homeManagerModules = {
        zsh = import ./_home_manager/mods/zsh.nix;
        tmux = import ./_home_manager/mods/tmux/tmux.nix;
        atuin = import ./_home_manager/mods/atuin.nix;
        zoxide = import ./_home_manager/mods/zoxide.nix;
        starship = import ./_home_manager/mods/starship.nix;
        direnv = import ./_home_manager/mods/direnv.nix;
        ssh = import ./_home_manager/mods/ssh.nix;
        git = import ./_home_manager/mods/git.nix;
        nix_deprecations = import ./_home_manager/mods/nix_deprecations.nix;

        launcher_rofi = import ./_home_manager/mods/launcher_rofi.nix;

        alacritty = import ./_home_manager/mods/alacritty.nix;
        kitty = import ./_home_manager/mods/kitty.nix;
        obs = import ./_home_manager/mods/obs.nix;
        postgres = import ./_home_manager/mods/postgres.nix;
        slicer = import ./_home_manager/mods/slicer.nix;
      };
    };
}
