{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:rycee/home-manager";

    # common.url = "path:../../../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # de_plasma.url = "path:../../../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";
    # impermanence.url = "path:../../flakes/impermanence";
    impermanence.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";
    # sec-agent replaces secrets-bao on this host.
    secrets_manager.url = "git+https://git.joshuabell.xyz/ringofstorms/secrets_manager.git";

    fleet-agent.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/fleet-agent";
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
        extraGroups = [
          "wheel"
          "networkmanager"
        ];

        hmModules = [
          inputs.common.homeManagerModules.kitty
        ];

        nixosModules = [
          inputs.impermanence.nixosModules.default
          ({
            ringofstorms.impermanence = {
              enable = true;
              disk = {
                boot = "/dev/disk/by-uuid/635D-F0DA";
                primary = "/dev/disk/by-uuid/82cb11a7-097a-4e95-b9f0-47dad95de9df";
                swap = "/dev/disk/by-partuuid/f0aeb9d7-d82d-4b94-8c30-6a4234554fa8";
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
              wallpapers = [
                ../../hosts/_shared_assets/wallpapers/pixel_cat_garage.png
              ];
            };
          })

          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.tmux
          inputs.common.nixosModules.boot_systemd
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.ssh_root
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
          ./firewall.nix
          (import ./impermanence.nix {
            impermanence = inputs.impermanence;
          })

          # Host-specific config
          ({ pkgs, ... }: {
            networking.networkmanager.enable = true;
            environment.systemPackages = with pkgs; [
              qdirstat
              google-chrome
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
              pkgs.spotify
              # Jellyseerr has no native client: open it as a Chrome app window.
              (pkgs.makeDesktopItem {
                name = "jellyseerr";
                desktopName = "Jellyseerr";
                comment = "Request new movies and shows";
                exec = "google-chrome-stable --app=https://media.joshuabell.xyz";
                icon = "folder-download";
                categories = [
                  "AudioVideo"
                  "Video"
                ];
              })
            ];
            programs.firefox.enable = true;

            # TV audio: disable the mini PC's unused internal USB 3.5mm codec so HDMI
            # (`alsa_card.pci-0000_00_1f.3`) is the only built-in sink (Bluetooth
            # headphones still take over when connected). Also ensure WirePlumber never
            # restores a persisted muted route on boot/login.
            services.pipewire.wireplumber.extraConfig."50-tv-hdmi-audio" = {
              "wireplumber.settings" = {
                "device.routes.default-sink-volume" = 1.0;
              };
              "monitor.alsa.rules" = [
                {
                  matches = [
                    { "device.name" = "alsa_card.usb-CSCTEK_USB_Audio_and_HID_A34004801402-00"; }
                  ];
                  actions.update-props = {
                    "device.disabled" = true;
                  };
                }
              ];
            };
            # Scrub any persisted `"mute":true` from default-routes BEFORE
            # WirePlumber starts, since state-routes.lua loads default-routes
            # into its in-memory state_table once at startup.
            systemd.user.services.wireplumber.serviceConfig.ExecStartPre = [
              (pkgs.writeShellScript "wireplumber-scrub-mute" ''
                routes="$HOME/.local/state/wireplumber/default-routes"
                if [ -f "$routes" ]; then
                  ${pkgs.gnused}/bin/sed -i 's/"mute":true/"mute":false/g' "$routes"
                fi
              '')
            ];
            systemd.user.services.tv-audio-unmute = {
              description = "Ensure TV HDMI audio sink is unmuted";
              wantedBy = [
                "pipewire.service"
                "default.target"
              ];
              after = [
                "pipewire.service"
                "wireplumber.service"
              ];
              path = [
                pkgs.wireplumber
                pkgs.coreutils
              ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                for _ in $(seq 1 20); do
                  if wpctl inspect @DEFAULT_AUDIO_SINK@ >/dev/null 2>&1; then
                    wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 || true
                    break
                  fi
                  sleep 0.25
                done
              '';
            };

            # Bluetooth (controllers, headphones). Pairings persist via the shared
            # `bluetooth` impermanence set (/var/lib/bluetooth).
            hardware.bluetooth = {
              enable = true;
              powerOnBoot = true;
              settings.General = {
                FastConnectable = true;
                Experimental = true; # battery level reporting
              };
            };

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
            home-manager.users.${primaryUser} =
              { config, lib, ... }:
              let
                apps = "/run/current-system/sw/share/applications";
                wallpaper = "${../../hosts/_shared_assets/wallpapers/pixel_cat_garage.png}";
                plasmashellrcFile = pkgs.writeText "plasmashellrc" ''
                  [Applets][1]
                  wallpaperplugin=org.kde.image

                  [Applets][1][Wallpaper][org.kde.image][General]
                  Image=file://${wallpaper}
                '';
                favs = [
                  {
                    id = "org.jellyfin.JellyfinDesktop";
                    name = "Jellyfin";
                    icon = "org.jellyfin.JellyfinDesktop";
                    exec = "jellyfin-desktop";
                    cats = "AudioVideo,Video,Player,TV";
                  }
                  {
                    id = "jellyseerr";
                    name = "Jellyseerr";
                    icon = "folder-download";
                    exec = "google-chrome-stable --app=https://media.joshuabell.xyz";
                    cats = "AudioVideo,Video";
                  }
                  {
                    id = "spotify";
                    name = "Spotify";
                    icon = "spotify-client";
                    exec = "spotify %U";
                    cats = "Audio,Music,Player,AudioVideo";
                  }
                  {
                    id = "google-chrome";
                    name = "Google Chrome";
                    icon = "google-chrome";
                    exec = "google-chrome-stable %U";
                    cats = "Network,WebBrowser";
                  }
                  {
                    id = "firefox";
                    name = "Firefox";
                    icon = "firefox";
                    exec = "firefox --name firefox %U";
                    cats = "Network,WebBrowser";
                  }
                ];
                favsFile = pkgs.writeText "bigscreen-favs" (
                  lib.concatImapStrings (i: f: ''
                    [Favs][${toString (i - 1)}]
                    categories=${f.cats}
                    comment=
                    desktopPath=${apps}/${f.id}.desktop
                    entryPath=${f.exec}
                    icon=${f.icon}
                    name=${f.name}
                    startupNotify=true
                    storageId=${f.id}.desktop

                  '') favs
                );
                # Desktop-only clutter hidden from the TV launcher (desktop entry names).
                hidden = [
                  "org.kde.konsole"
                  "kitty"
                  "gvim"
                  "org.gnome.Meld"
                  "qdirstat"
                  "org.kde.kate"
                  "org.kde.kwrite"
                  "org.kde.akonadiconsole"
                  "org.kde.akonadiimportwizard"
                  "org.kde.kmail2"
                  "org.kde.kontact"
                  "org.kde.ktnef"
                  "org.kde.merkuro.calendar"
                  "org.kde.merkuro.contact"
                  "org.kde.merkuro.mail"
                  "org.kde.kmenuedit"
                  "org.kde.kwalletmanager"
                  "org.kde.plasma-systemmonitor"
                  "org.kde.khelpcenter"
                  "org.kde.kinfocenter"
                  "org.kde.ark"
                  "org.kde.okular"
                  "org.kde.spectacle"
                  "org.kde.qrca"
                  "org.kde.plasma.emojier"
                  "org.kde.discover"
                  "org.kde.dolphin"
                  "kbd-layout-viewer5"
                  "fcitx5-configtool"
                  "org.fcitx.fcitx5-migrator"
                  "nixos-manual"
                  "kdesystemsettings"
                  "org.kde.kdeconnect.nonplasma"
                  "org.kde.plasma.bigscreen.uvcviewer"
                  "com.google.Chrome"
                  # Bigscreen's own defaults (this file replaces its list):
                  "org.kde.drkonqi.coredump.gui"
                  "org.kde.kdeconnect.app"
                  "org.kde.kdeconnect.sms"
                  "plasma-bigscreen-swap-session"
                ];
                blacklistFile = pkgs.writeText "applications-blacklistrc" ''
                  [Applications]
                  blacklist=${lib.concatStringsSep "," hidden}
                '';
              in
              {
                # Default browser (Bigscreen ships aura-browser in its kdeglobals defaults;
                # ~/.config/kdeglobals outranks it).
                programs.plasma.configFile.kdeglobals.General.BrowserApplication = "google-chrome.desktop";
                # Plasma Bigscreen has no mute indicator or unmute toggle in its
                # audio settings KCM (and its QML volume slider is broken in 6.7),
                # so unbind the remote's Mute key to prevent global sink mute from
                # locking audio off.
                programs.plasma.shortcuts.kmix.mute = [ ];
                # Ensure plasma-manager's wallpaper script still runs on Bigscreen
                # login while skipping the desktop panel/layout scripts.
                xdg.configFile."autostart/plasma-manager-autostart.desktop".text = lib.mkOverride 40 ''
                  [Desktop Entry]
                  Type=Application
                  Name=Plasma Manager theme application
                  Exec=${pkgs.writeShellScript "plasma-manager-autostart" ''
                    case "''${DESKTOP_SESSION:-}" in
                      plasma-bigscreen*)
                        for script in ${config.xdg.dataHome}/plasma-manager/scripts/0_script_reset_lastrun_desktopscripts.sh \
                                      ${config.xdg.dataHome}/plasma-manager/scripts/*wallpaper*.sh; do
                          [ -x "$script" ] && "$script"
                        done
                        exit 0
                        ;;
                    esac
                    exec ${config.xdg.dataHome}/plasma-manager/run_all.sh
                  ''}
                  X-KDE-autostart-condition=ksmserver
                '';
                home.activation.bigscreenSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
                  install -Dm644 ${favsFile} "$HOME/.config/bigscreen-favs"
                  install -Dm644 ${blacklistFile} "$HOME/.config/applications-blacklistrc"
                  install -Dm600 ${plasmashellrcFile} "$HOME/.config/plasmashellrc"
                  if [ -f "$HOME/.local/state/wireplumber/default-routes" ]; then
                    ${pkgs.gnused}/bin/sed -i 's/"mute":true/"mute":false/g' "$HOME/.local/state/wireplumber/default-routes"
                  fi
                '';
              };
          })
        ];
      };
    };
}
