{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-24.11";
    cosmic = {
      url = "github:lilyinstarlight/nixos-cosmic";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs-stable.follows = "nixpkgs-stable";
    };
  };

  outputs =
    {
      cosmic,
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
          with lib;
          {
            options.mods.de_cosmic = {
              users = mkOption {
                type = types.listOf types.str;
                description = "Users to apply cosmic DE settings to.";
                default = [
                  "root"
                ] ++ (lib.optionals (config.mods.common.primaryUser != null) [ config.mods.common.primaryUser ]);
              };
            };

            imports = [
              cosmic.nixosModules.default
            ];

            config = {

              # Use cosmic binary cache
              nix.settings = {
                substituters = [ "https://cosmic.cachix.org/" ];
                trusted-public-keys = [ "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE=" ];
              };

              environment.systemPackages = with pkgs; [
                wl-clipboard
              ];

              # Enable cosmic
              services.desktopManager.cosmic.enable = true;
              services.displayManager.cosmic-greeter.enable = true;
              environment.cosmic.excludePackages = with pkgs; [
                cosmic-edit
                cosmic-term
                cosmic-store
              ];

              # Config
              environment.etc = lib.mkIf (config.mods.de_cosmic.users != null) (
                lib.genAttrs config.mods.de_cosmic.users (user: {
                  source = ./config;
                  target = "/home/${user}/.config/cosmic";
                })
              );
            };
          };
      };
    };
}
