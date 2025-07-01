{
  inputs = {
    # NOTE if you add/change any inputs here also add them in the TOP level repo's flake.nix
    home-manager.url = "github:rycee/home-manager/release-25.05";
    ragenix.url = "github:yaxitech/ragenix";
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";

    nixpkgs_opencode.url = "github:nixos/nixpkgs/pull/419604/head";
  };

  outputs =
    {
      home-manager,
      ragenix,
      nix-flatpak,
      nixpkgs_opencode,
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
              (
                { ... }:
                {
                  nixpkgs.overlays = [
                    (final: prev: {
                      opencode = nixpkgs_opencode.legacyPackages.${prev.system}.opencode;
                    })
                  ];
                }
              )
              home-manager.nixosModules.home-manager
              ragenix.nixosModules.age
              nix-flatpak.nixosModules.nix-flatpak
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
          forgejo = import ./_containers/forgejo.nix;
          obsidian_sync = import ./_containers/obsidian_sync.nix;
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

        kitty = import ./_home_manager/mods/kitty.nix;
        launcher_rofi = import ./_home_manager/mods/launcher_rofi.nix;

        obs = import ./_home_manager/mods/obs.nix;
        postgres = import ./_home_manager/mods/postgres.nix;
        slicer = import ./_home_manager/mods/slicer.nix;

        alacritty = import ./_home_manager/mods/alacritty.nix;
      };
    };
}
