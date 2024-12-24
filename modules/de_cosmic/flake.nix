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
      self,
      cosmic,
      nixpkgs,
      ...
    }:
    let
      lib = nixpkgs.lib;

      cosmicConfigDir = ./config;
      cosmicFiles = builtins.attrNames (builtins.readDir cosmicConfigDir);
      cosmicConfigFiles = builtins.map (fileName: {
        name = "cosmic/${fileName}";
        value = {
          source = "${cosmicConfigDir}/${fileName}";
        };
      }) cosmicFiles;
      cosmicConfigFilesAttrs = builtins.listToAttrs cosmicConfigFiles;
    in
    with lib;
    {
      nixosModules = {
        default = {
          options = {
            # mods.de_cosmic = {
            #   nvidiaExtraDisplayFix = mkOption {
            #     type = types.bool;
            #     default = false;
            #     description = ''
            #       Enable extra display fix for nvidia cards.
            #     '';
            #   };
            # };
          };
          config = {
            imports = [
              cosmic.nixosModules.default
            ];

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
            home-manager.backupFileExtension = "bak";
            home-manager.users.${settings.user.username} = {
              xdg.configFile = cosmicConfigFilesAttrs;
            };
          };
        };
      };
    };
}
