{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:rycee/home-manager";

    # common.url = "path:../../../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # de_plasma.url = "path:../../../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";
    # impermanence_mod.url = "path:../../flakes/impermanence";
    impermanence_mod.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";
    # sec-agent replaces secrets-bao on this host.
    secrets_manager.url = "git+https://git.joshuabell.xyz/ringofstorms/secrets_manager.git";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    { ... }@inputs:
    let
      fleet = import ../fleet.nix;
      constants = import ./_constants.nix;
      primaryUser = constants.host.primaryUser;
    in
    {
      nixosConfigurations.${constants.host.name} = fleet.mkHost {
        inherit inputs constants;
        secretsRole = "machines-lowtrust";
        authMethod = "hashedPassword";
        authValue = "$y$j9T$gEfQmnTUrDRwmBHl5F9Jy/$s6UJyVizYX6kci7MgkG4uk/LesEfOPT56m.rQaeHtcB";
        mutableUsers = false;
        extraGroups = [ "wheel" "networkmanager" ];

        hmModules = [
          inputs.common.homeManagerModules.kitty
        ];

        nixosModules = [
          inputs.impermanence_mod.nixosModules.default
          ({
            ringofstorms.impermanence = {
              enable = true;
              disk = {
                boot = "/dev/disk/by-uuid/635D-F0DA";
                primary = "/dev/disk/by-uuid/82cb11a7-097a-4e95-b9f0-47dad95de9df";
                swap = "/dev/disk/by-uuid/29c89516-e6ed-4f91-adf7-646451a8e26f";
              };
              encrypted = true;
              usbKey = true;
            };
          })

          inputs.ros_neovim.nixosModules.default
          ({ ringofstorms-nvim.includeAllRuntimeDependencies = true; })

          inputs.de_plasma.nixosModules.default
          ({
            ringofstorms.dePlasma = {
              enable = true;
              gpu.intel.enable = true;
              sddm.autologinUser = "luser";
            };
          })

          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.tmux
          inputs.common.nixosModules.boot_systemd
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.jetbrains_font
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.no_sleep
          inputs.common.nixosModules.timezone_auto
          inputs.common.nixosModules.tty_caps_esc
          inputs.common.nixosModules.zsh
          inputs.common.nixosModules.tailnet

          (import ../sec-agent.nix {
            inherit inputs constants;
            role = "machines-lowtrust";
          })

          ./hardware-configuration.nix
          (import ./impermanence.nix {
            impermanence_mod = inputs.impermanence_mod;
          })

          # Host-specific config
          ({ pkgs, ... }: {
            networking.networkmanager.enable = true;
            users.users.root.openssh.authorizedKeys.keys = [ fleet.global.sshPubKey ];
            environment.systemPackages = with pkgs; [
              qdirstat google-chrome
              jellyfin-media-player
              libva-utils # vainfo: verify Intel hardware decode
            ];
          })

          # ── TV media box (replaces gp3) ─────────────────────────────
          # Plasma Bigscreen (Plasma >= 6.7, hence nixos-unstable) is the
          # autologin session; regular Plasma stays selectable in SDDM.
          ({ pkgs, ... }: {
            services.displayManager.sessionPackages = [ pkgs.kdePackages.plasma-bigscreen ];
            services.displayManager.defaultSession = "plasma-bigscreen-wayland";
            environment.systemPackages = [
              pkgs.kdePackages.plasma-bigscreen
              # Jellyseerr has no native client: open it as a Chrome app window.
              (pkgs.makeDesktopItem {
                name = "jellyseerr";
                desktopName = "Jellyseerr";
                comment = "Request new movies and shows";
                exec = "google-chrome-stable --app=https://media.joshuabell.xyz";
                icon = "folder-download";
                categories = [ "AudioVideo" "Video" ];
              })
            ];
            programs.firefox.enable = true;

            # Steam: Remote Play client for joe; local games are not a goal.
            programs.steam = {
              enable = true;
              remotePlay.openFirewall = true;
            };
            hardware.steam-hardware.enable = true; # controller udev rules
            # Steam forwards client input through /dev/uinput.
            services.udev.extraRules = ''
              KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input"
            '';
            users.users.${primaryUser}.extraGroups = [ "input" ];

            # Homescreen favorites + app list cleanup. Home is wiped every boot
            # (impermanence), so seed writable copies on each HM activation;
            # in-session tweaks last until reboot. Favorites format is from
            # plasma-bigscreen favslistmodel.cpp ([Favs][<index>] groups,
            # launched by storageId). ~/.config outranks Bigscreen's own
            # ~/.config/plasma-bigscreen defaults (XDG_CONFIG_DIRS).
            home-manager.users.${primaryUser} = { lib, ... }:
              let
                apps = "/run/current-system/sw/share/applications";
                favs = [
                  { id = "org.jellyfin.JellyfinDesktop"; name = "Jellyfin"; icon = "org.jellyfin.JellyfinDesktop"; exec = "jellyfin-desktop"; cats = "AudioVideo,Video,Player,TV"; }
                  { id = "jellyseerr"; name = "Jellyseerr"; icon = "folder-download"; exec = "google-chrome-stable --app=https://media.joshuabell.xyz"; cats = "AudioVideo,Video"; }
                  { id = "google-chrome"; name = "Google Chrome"; icon = "google-chrome"; exec = "google-chrome-stable %U"; cats = "Network,WebBrowser"; }
                  { id = "firefox"; name = "Firefox"; icon = "firefox"; exec = "firefox --name firefox %U"; cats = "Network,WebBrowser"; }
                ];
                favsFile = pkgs.writeText "bigscreen-favs" (lib.concatImapStrings (i: f: ''
                  [Favs][${toString (i - 1)}]
                  categories=${f.cats}
                  comment=
                  desktopPath=${apps}/${f.id}.desktop
                  entryPath=${f.exec}
                  icon=${f.icon}
                  name=${f.name}
                  startupNotify=true
                  storageId=${f.id}.desktop

                '') favs);
                # Desktop-only clutter hidden from the TV launcher (desktop entry names).
                hidden = [
                  "org.kde.konsole" "kitty" "gvim" "org.gnome.Meld" "qdirstat"
                  "org.kde.kate" "org.kde.kwrite" "org.kde.akonadiconsole"
                  "org.kde.akonadiimportwizard" "org.kde.kmail2" "org.kde.kontact"
                  "org.kde.ktnef" "org.kde.merkuro.calendar" "org.kde.merkuro.contact"
                  "org.kde.merkuro.mail" "org.kde.kmenuedit" "org.kde.kwalletmanager"
                  "org.kde.plasma-systemmonitor" "org.kde.khelpcenter" "org.kde.kinfocenter"
                  "org.kde.ark" "org.kde.okular" "org.kde.spectacle" "org.kde.qrca"
                  "org.kde.plasma.emojier" "org.kde.discover" "org.kde.dolphin"
                  "kbd-layout-viewer5" "fcitx5-configtool" "org.fcitx.fcitx5-migrator"
                  "nixos-manual" "kdesystemsettings" "org.kde.kdeconnect.nonplasma"
                  "org.kde.plasma.bigscreen.uvcviewer" "com.google.Chrome"
                  # Bigscreen's own defaults (this file replaces its list):
                  "org.kde.drkonqi.coredump.gui" "org.kde.kdeconnect.app"
                  "org.kde.kdeconnect.sms" "plasma-bigscreen-swap-session"
                ];
                blacklistFile = pkgs.writeText "applications-blacklistrc" ''
                  [Applications]
                  blacklist=${lib.concatStringsSep "," hidden}
                '';
              in {
                # Default browser (Bigscreen ships aura-browser in its kdeglobals defaults;
                # ~/.config/kdeglobals outranks it).
                programs.plasma.configFile.kdeglobals.General.BrowserApplication = "google-chrome.desktop";
                home.activation.bigscreenSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
                  install -Dm644 ${favsFile} "$HOME/.config/bigscreen-favs"
                  install -Dm644 ${blacklistFile} "$HOME/.config/applications-blacklistrc"
                '';
              };
          })
        ];
      };
    };
}
