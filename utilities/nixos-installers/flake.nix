{
  description = "NixOS installer ISOs with extra bits I like";

  inputs = {
    stable.url = "github:nixos/nixpkgs/nixos-25.05";
    unstable.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { stable, unstable, ... }:
    let
      lib = stable.lib;
      systems = lib.systems.flakeExposed;

      channels = {
        stable = stable;
        unstable = unstable;
      };

      # Build a NixOS system that is an installation ISO with SSH enabled
      minimal =
        { nixpkgs, system }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            (
              { pkgs, modulesPath, ... }:
              {
                imports = [
                  (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
                ];

                nix.settings.experimental-features = [
                  "nix-command"
                  "flakes"
                ];

                environment.systemPackages = with pkgs; [
                  neovim
                  fastfetch
                  fzf
                ];

                services.openssh = {
                  enable = true;
                  settings = {
                    PermitRootLogin = "yes";
                    PasswordAuthentication = true;
                  };
                };

                users.users.nixos = {
                  password = "password";
                  initialHashedPassword = lib.mkForce null;
                };
                users.users.root = {
                  password = "password";
                  initialHashedPassword = lib.mkForce null;
                };
              }
            )
          ];
        };

      mkIsoPkgsForSystem =
        system:
        builtins.listToAttrs (
          builtins.map (channelName: {
            name = "iso-minimal-${channelName}";
            value =
              (minimal {
                nixpkgs = channels.${channelName};
                inherit system;
              }).config.system.build.isoImage;
          }) (builtins.attrNames channels)
        );
    in
    {
      packages = lib.genAttrs systems (system: mkIsoPkgsForSystem system);
    };
}
