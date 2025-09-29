{
  inputs = {
    # NOTE if you add/change any inputs here also add them in the TOP level repo's flake.nix
    home-manager.url = "github:rycee/home-manager/release-25.05";
    ragenix.url = "github:yaxitech/ragenix";
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";

    # disabled for now
    hyprland.url = "github:hyprwm/Hyprland";
  };

  outputs =
    {
      home-manager,
      ragenix,
      nix-flatpak,
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
              home-manager.nixosModules.default
              ragenix.nixosModules.age
              nix-flatpak.nixosModules.nix-flatpak
              hyprland.nixosModules.default
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
              nixpkgs.overlays = [
                # (final: prev: {
                #   wayland-protocols =
                #     nixpkgs-unstable.legacyPackages.${prev.stdenv.hostPlatform.system}.wayland-protocols;
                # })
              ];
              _module.args = {
                inherit ragenix;
                inherit hyprland;
                hyprlandPkgs = import hyprland.inputs.nixpkgs {
                  system = pkgs.stdenv.hostPlatform.system;
                  config = config.nixpkgs.config or { };
                };
              };
            };
          };
        containers = {
          forgejo = import ./_containers/forgejo.nix;
        };
      };
      homeManagerModules = {
        # hyprland = hyprland.homeManagerModules.default;

        zsh = import ./_home_manager/mods/zsh.nix;
        tmux = import ./_home_manager/mods/tmux/tmux.nix;
        atuin = import ./_home_manager/mods/atuin.nix;
        zoxide = import ./_home_manager/mods/zoxide.nix;
        starship = import ./_home_manager/mods/starship.nix;
        direnv = import ./_home_manager/mods/direnv.nix;
        ssh = import ./_home_manager/mods/ssh.nix;
        git = import ./_home_manager/mods/git.nix;
        nix_deprecations = import ./_home_manager/mods/nix_deprecations.nix;

        alacritty = import ./_home_manager/mods/alacritty.nix;
        foot = import ./_home_manager/mods/foot.nix;
        kitty = import ./_home_manager/mods/kitty.nix;
        launcher_rofi = import ./_home_manager/mods/launcher_rofi.nix;

        obs = import ./_home_manager/mods/obs.nix;
        postgres = import ./_home_manager/mods/postgres.nix;
        slicer = import ./_home_manager/mods/slicer.nix;

      };
    };
}
