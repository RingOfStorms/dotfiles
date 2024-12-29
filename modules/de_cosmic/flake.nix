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
          let
            cosmicConfigDir = ./config;
            cosmicFiles = builtins.attrNames (builtins.readDir cosmicConfigDir);
            cosmicConfigFiles = map (fileName: {
              name = "cosmic/${fileName}";
              value = {
                source = "${cosmicConfigDir}/${fileName}";
                # mode = "0644";
              };
            }) cosmicFiles;
            cosmicConfigFilesAttrs = builtins.listToAttrs cosmicConfigFiles;
          in
          with lib;
          {
            options.mods.de_cosmic = {
              users = mkOption {
                type = types.listOf types.str;
                description = "Users to apply cosmic DE settings to.";
                default = (
                  lib.optionals (config.mods.common.primaryUser != null) [ config.mods.common.primaryUser ]
                );
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

              # there are cosmic-greeter files in /var/lib/cosmic-greeter/ and ~/.local/state/cosmic
              # Config TODO my attempt to make this not home-manager driven...
              # environment.etc = cosmicConfigFilesAttrs;
              # systemd.user.tmpfiles.rules = [
              #   "L %h/.config/cosmic - - - - /etc/cosmic"
              # ];

              # Config TODO come up with a non home-manager way to do this. I dont want this flake to require home-manager from somewhere else to exist
              home-manager.users = listToAttrs (
                map (name: {
                  inherit name;
                  value = {
                    xdg.configFile = cosmicConfigFilesAttrs;
                  };
                }) config.mods.de_cosmic.users
              );
            };
          };
      };
    };
}
