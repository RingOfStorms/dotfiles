{
  nixConfig = {
    extra-substituters = [ "https://herdr.cachix.org" ];
    extra-trusted-public-keys = [ "herdr.cachix.org-1:3nH7IStRsS0ASfdonA0DCRR2ZrSCeWitZ7Kwew0cR4I=" ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    home-manager.url = "github:rycee/home-manager/release-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    # common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    common.url = "path:../../flakes/common";
    secrets_manager.url = "git+https://git.joshuabell.xyz/ringofstorms/secrets_manager.git";
    flatpaks.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/flatpaks";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";
    stt_ime.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/stt_ime";
    ports.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/ports";
    containers.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/containers";
    omp-flake.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/omp";
    paseo.url = "path:../../flakes/paseo";
    paseo.inputs.nixpkgs.follows = "nixpkgs";
    herdr-nix.url = "github:herdrdev/herdr-nix";
    herdr-nix.inputs.nixpkgs.follows = "nixpkgs";
    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
    opencode.url = "github:anomalyco/opencode/cd9a14a6b688d4021bee381dfd39d2cef9c0f862";
  };

  outputs = { nixpkgs-unstable, ... }@inputs:
    let
      fleet = import "${inputs.common}/../../hosts/fleet.nix";
      constants = import ./_constants.nix;
      overlayIp = constants.host.overlayIp;
      primaryUser = constants.host.primaryUser;
    in
    {
      nixosConfigurations.${constants.host.name} = fleet.mkHost {
        inherit inputs constants;
        nixpkgsUnstable = nixpkgs-unstable;
        authMethod = "hashedPassword";
        authValue = "$y$j9T$GvwwBotPdCjybuJeTGeLe/$but0teo8CQusyzxurhb42vpt/Ox1EUmARb24VMSZz14";
        mutableUsers = false;
        extraGroups = [ "wheel" "networkmanager" "video" "render" "input" "dialout" ];
        hmModules = [
          inputs.common.homeManagerModules.kitty
          inputs.common.homeManagerModules.foot
          inputs.common.homeManagerModules.launcher_rofi
          inputs.common.homeManagerModules.slicer
          ({ ... }: {
            programs.ssh.matchBlocks = {
              "joe_" = { hostname = fleet.hosts.joe.lanIp; user = fleet.hosts.joe.user; };
              "gp3_" = { hostname = fleet.hosts.gp3.lanIp; user = fleet.hosts.gp3.user; };
            };
          })
        ];
        nixosModules = [
          inputs.de_plasma.nixosModules.default
          ({ ringofstorms.dePlasma = { enable = true; gpu.amd.enable = true; noScreenOff = true; }; })
          inputs.stt_ime.nixosModules.default
          ({ ringofstorms.sttIme = { enable = true; gpuBackend = "hip"; useGpu = true; model = "large-v3-turbo"; }; })
          inputs.ports.nixosModules.default
          ({ ringofstorms.ports.enable = true; })
          inputs.ros_neovim.nixosModules.default
          ({ ringofstorms-nvim.includeAllRuntimeDependencies = true; })
          inputs.flatpaks.nixosModules.default
          inputs.containers.nixosModules.default
          inputs.common.nixosModules.essentials
          (import ../../flakes/common/nix_modules/git/default.nix)
          inputs.common.nixosModules.tmux
          inputs.common.nixosModules.boot_systemd
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.jetbrains_font
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.no_sleep
          inputs.common.nixosModules.podman
          inputs.common.nixosModules.q_flipper
          inputs.common.nixosModules.tailnet
          (import ./sec-agent.nix { inherit inputs constants; })
          inputs.common.nixosModules.zsh
          inputs.common.nixosModules.rage
          inputs.common.nixosModules.more_filesystems
          inputs.paseo.nixosModules.default
          ./paseo.nix
          inputs.omp-flake.nixosModules.default
          ./pi.nix
          ./herdr.nix
          ({ pkgs, config, ... }: {
            environment.systemPackages = [ config.services.paseoBareMetal.opencodePackage pkgs.claude-code pkgs.code-cursor pkgs.zed-editor ];
            environment.shellAliases = let
              no_proxy = "NO_PROXY='h001.net.joshuabell.xyz,*.ts.net,127.0.0.1,localhost,100.64.0.0/10'";
              nono_base = "nono run --allow-cwd --silent --read \"$(git rev-parse --git-common-dir 2>/dev/null || echo /tmp)\"";
            in {
              mva = "${no_proxy} ${nono_base} --profile mva-full -- /home/josh/projects/mva/target/release/mva";
              mva_ = "${no_proxy} /home/josh/projects/mva/target/release/mva";
              oc = "${no_proxy} ${nono_base} --profile opencode-full -- opencode --standalone";
              oc_ = "${no_proxy} opencode --standalone";
              occ = "oc -c";
              cc = "${no_proxy} ${nono_base} --profile claude-code-full -- claude";
              cur = "${no_proxy} ${nono_base} --profile claude-code-full -- cursor";
              zed = "${no_proxy} ${nono_base} --profile claude-code-full -- zeditor";
              npm = "${no_proxy} ${nono_base} --profile npm -- npm";
              pi = "${no_proxy} ${nono_base} --profile pi -- pi";
              pi_ = "${no_proxy} command pi";
            };
          })
          inputs.beszel.nixosModules.agent
          ({ services.beszel.agent.environment.EXTRA_FILESYSTEMS = "/mnt/nvme1tb__nvme1tb"; beszelAgent = { listen = "${overlayIp}:45876"; token = "20208198-87c2-4bd1-ab09-b97c3b9c6a6e"; }; })
          ./configuration.nix
          ./hardware-configuration.nix
          (import ./containers.nix { inherit inputs; })
          ./vms.nix
          ./nono.nix
          ./homepage-dashboard.nix
          ./nginx.nix
          ({ pkgs, ... }: {
            environment.systemPackages = with pkgs; [ vlang pavucontrol nfs-utils jellyfin-media-player element-desktop vesktop discord ];
            services.flatpak.packages = [ "org.signal.Signal" "com.spotify.Client" "com.bitwarden.desktop" "org.openscad.OpenSCAD" "org.blender.Blender" ];
          })
        ];
      };
    };
}
