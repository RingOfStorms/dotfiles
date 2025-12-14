{
  description = "NixOS installer ISOs with extra bits I like";

  inputs = {
    stable.url = "github:nixos/nixpkgs/nixos-25.11";
    unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    {
      stable,
      unstable,
      ros_neovim,
      ...
    }:
    let
      lib = stable.lib;
      systems = lib.systems.flakeExposed;

      channels = {
        stable = stable;
        unstable = unstable;
      };

      # Build a NixOS system that is an installation ISO with SSH enabled and bcachefs
      minimal =
        { nixpkgs, system }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ros_neovim.nixosModules.default
            (
              { pkgs, modulesPath, ... }:
              {
                imports = [
                  (modulesPath + "/installer/cd-dvd/installation-cd-minimal-new-kernel-no-zfs.nix")
                ];

                nix.settings.experimental-features = [
                  "nix-command"
                  "flakes"
                ];

                environment.systemPackages = with pkgs; [
                  fastfetch
                  fzf

                  # bcachefs
                  # Required as a workaround for bug
                  # https://github.com/NixOS/nixpkgs/issues/32279
                  keyutils
                ];
                boot.supportedFilesystems = [ "bcachefs" ];

                environment.shellAliases = {
                  n = "nvim";
                };

                services.openssh = {
                  enable = true;
                  settings = {
                    PermitRootLogin = "yes";
                    PasswordAuthentication = true;
                  };
                };

                programs.zsh.enable = true;
                environment.pathsToLink = [ "/share/zsh" ];
                users.defaultUserShell = pkgs.zsh;
                system.userActivationScripts.zshrc = "touch .zshrc";
                programs.starship.enable = true;

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
