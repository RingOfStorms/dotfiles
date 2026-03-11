{
  description = "NixOS installer ISOs with bcachefs + disko support";

  inputs = {
    stable.url = "github:nixos/nixpkgs/nixos-25.11";
    unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    # impermanence_mod.url = "path:../../flakes/impermanence";
    impermanence_mod.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";
    disko.url = "github:nix-community/disko/latest";
    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    {
      stable,
      unstable,
      impermanence_mod,
      disko,
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

      diskoConfig = "${impermanence_mod}/disko-bcachefs.nix";

      minimal =
        { nixpkgs, system }:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          diskoFormatScript = pkgs.writeShellScriptBin "disko_format" ''
            set -euo pipefail

            usage() {
              echo "Usage: disko_format <disk> [swap_size] [--encrypted]"
              echo ""
              echo "  disk        Block device to partition (e.g. /dev/nvme0n1)"
              echo "  swap_size   Swap partition size (default: 8G)"
              echo "  --encrypted Enable bcachefs encryption (writes passphrase to /tmp/bcachefs.key)"
              echo ""
              echo "Examples:"
              echo "  disko_format /dev/nvme0n1 16G --encrypted"
              echo "  disko_format /dev/sda"
              exit 1
            }

            if [ $# -lt 1 ]; then
              usage
            fi

            DISK="$1"
            SWAP="''${2:-8G}"
            ENCRYPTED=""

            for arg in "$@"; do
              if [ "$arg" = "--encrypted" ]; then
                ENCRYPTED="true"
              fi
            done

            if [ ! -b "$DISK" ]; then
              echo "Error: $DISK is not a block device"
              exit 1
            fi

            echo "=== disko_format ==="
            echo "  Disk:      $DISK"
            echo "  Swap:      $SWAP"
            echo "  Encrypted: ''${ENCRYPTED:-false}"
            echo ""
            echo "This will DESTROY all data on $DISK."
            read -rp "Continue? [y/N] " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
              echo "Aborted."
              exit 1
            fi

            ARGS=(
              --mode destroy,format,mount
              ${diskoConfig}
              --arg disk "\"$DISK\""
              --arg swapSize "\"$SWAP\""
            )

            if [ -n "$ENCRYPTED" ]; then
              if [ ! -f /tmp/bcachefs.key ]; then
                echo ""
                echo "Encrypted mode requires a passphrase file at /tmp/bcachefs.key"
                echo "Create it with: echo -n 'your-passphrase' > /tmp/bcachefs.key"
                exit 1
              fi
              ARGS+=(--arg encrypted true)
            fi

            echo ""
            echo "Running disko..."
            ${disko.packages.${system}.disko}/bin/disko "''${ARGS[@]}"

            echo ""
            echo "Done. Check mounts with: mount | grep /mnt"
            echo "If subvolumes are not mounted, see Step 3 in the readme."
          '';
        in
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

                boot.supportedFilesystems = [ "bcachefs" ];

                environment.systemPackages = with pkgs; [
                  fastfetch
                  fzf
                  parted

                  dmidecode
                  lshw

                  # bcachefs -- keyutils required as workaround for
                  # https://github.com/NixOS/nixpkgs/issues/32279
                  keyutils
                  bcachefs-tools

                  # disko with bundled config
                  diskoFormatScript
                ];

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
                  openssh.authorizedKeys.keys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2KFSRkViT+asBTjCgA7LNP3SHnfNCW+jHbV08VUuIi nix2nix"
                  ];
                };
                users.users.root = {
                  password = "password";
                  initialHashedPassword = lib.mkForce null;
                  openssh.authorizedKeys.keys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2KFSRkViT+asBTjCgA7LNP3SHnfNCW+jHbV08VUuIi nix2nix"
                  ];
                };
              }
            )
          ];
        };

      mkIsoPkgsForSystem =
        system:
        builtins.listToAttrs (
          builtins.map (channelName: {
            name = "iso-${channelName}";
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
