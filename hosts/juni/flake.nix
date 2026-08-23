{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    home-manager.url = "github:rycee/home-manager/release-26.05";

    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    # Use relative to get current version for testing
    # impermanence.url = "path:../../flakes/impermanence";
    impermanence.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # sec-agent replaces secrets-bao on this host.
    secrets_manager.url = "git+https://git.joshuabell.xyz/ringofstorms/secrets_manager.git";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
    # de_plasma.url = "path:../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";
    # stt_ime.url = "path:../../flakes/stt_ime";
    stt_ime.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/stt_ime";
    # ports.url = "path:../../flakes/ports";
    ports.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/ports";

    nono.url = "github:always-further/nono/6b00932fe80a52b65f3718bb900878287640cc31";
    nono.flake = false;
    # Used to pin a newer rustc than what nixpkgs ships (needed by nono).
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    { nixpkgs-unstable, ... }@inputs:
    let
      fleet = import ../fleet.nix;
      constants = import ./_constants.nix;
      primaryUser = constants.host.primaryUser;
    in
    {
      nixosConfigurations.${constants.host.name} = fleet.mkHost {
        inherit inputs constants;
        nixpkgsUnstable = nixpkgs-unstable;
        # secrets-bao disabled — juni is cut over to sec-agent.
        authMethod = "hashedPassword";
        authValue = "$y$j9T$b66ZAxtTo75paZx.mnXyK.$ej0eKS3Wx4488qDfjUJSP0nsUe5TBzw31VbXR19XrQ4";
        mutableUsers = false;

        hmModules = [
          inputs.common.homeManagerModules.kitty

          # ── On-screen keyboard (tablet mode) ────────────────────────────
          # juni is a Framework 12 convertible. In tablet mode the physical
          # keyboard is disabled; KWin only shows an on-screen keyboard when a
          # virtual-keyboard input method is registered in kwinrc's
          # [Wayland] InputMethod slot. The shared de_plasma module points that
          # slot at fcitx5 (for Japanese/Mozc), which is a text input method,
          # not an OSK — so nothing popped up on text-field focus.
          #
          # Override the slot to maliit-keyboard here. fcitx5 continues to work
          # via its own Wayland text-input frontend (waylandFrontend = true in
          # the shared module), so Japanese input is unaffected.
          #
          # KWin 6.5 has no hide method for the virtual keyboard. A key
          # press from the built-in keyboard is unambiguous evidence that
          # the laptop is back in laptop mode, so hide Maliit through the
          # KWin D-Bus API. This does not disable Maliit; touching a text
          # field in tablet mode can show it again.
          (
            { pkgs, lib, ... }:
            {
              programs.plasma.configFile.kwinrc.Wayland.InputMethod = lib.mkForce
                "${pkgs.maliit-keyboard}/share/applications/com.github.maliit.keyboard.desktop";

              # Watch the stable built-in keyboard device. The keyboard is
              # disabled/inaccessible in tablet mode, so virtual keyboard
              # presses never trigger this watcher.
              systemd.user.services.maliit-hide-on-physical-keyboard = {
                Unit = {
                  Description = "Hide Maliit after returning to the physical keyboard";
                  PartOf = [ "plasma-workspace.target" ];
                  After = [ "plasma-kwin_wayland.service" ];
                };
                Service = {
                  ExecStart = pkgs.writeShellScript "maliit-hide-on-physical-keyboard" ''
                    set -euo pipefail
                    device=/dev/input/by-path/platform-i8042-serio-0-event-kbd
                    visible_command="${pkgs.systemd}/bin/busctl --user get-property org.kde.KWin /VirtualKeyboard org.kde.kwin.VirtualKeyboard visible | ${pkgs.gnugrep}/bin/grep -q 'b true'"
                    hide_command="${pkgs.systemd}/bin/busctl --user set-property org.kde.KWin /VirtualKeyboard org.kde.kwin.VirtualKeyboard active b false"

                    while [ ! -r "$device" ]; do
                      ${pkgs.coreutils}/bin/sleep 1
                    done

                    # Check visibility at most once every two seconds so normal
                    # typing does not spawn a D-Bus process for every key.
                    ${pkgs.coreutils}/bin/stdbuf -oL ${pkgs.evtest}/bin/evtest "$device" 2>/dev/null \
                      | ${pkgs.gawk}/bin/awk -v visibleCmd="$visible_command" -v hideCmd="$hide_command" '
                          BEGIN { lastCheck = -2 }
                          /type 1 \(EV_KEY\).*value 1/ {
                            now = systime();
                            if (now - lastCheck >= 2) {
                              lastCheck = now;
                              if (system(visibleCmd) == 0) {
                                system(hideCmd);
                              }
                            }
                          }
                        '
                  '';
                  Restart = "always";
                  RestartSec = 1;
                };
                Install.WantedBy = [ "plasma-workspace.target" ];
              };
            }
          )

          # ── Silence fcitx5's KDE Wayland startup nag ────────────────────
          # Because maliit occupies KWin's single [Wayland] InputMethod slot,
          # fcitx5 is no longer KWin's *registered* input method and shows a
          # "Fcitx should be launched by KWin ... select Fcitx 5 in Virtual
          # keyboard" tip on every login. Japanese input still works fine via
          # fcitx5's text-input frontend, so this tip is pure noise here.
          # The tip's id (found in fcitx5's libwayland.so) is
          # "wayland-diagnose-kde"; listing it in the notifications addon's
          # HiddenNotifications permanently suppresses just that message.
          #
          # NOTE 1: HiddenNotifications is a *list* option. fcitx5 unmarshals
          # list options from indexed subkeys ("Key/0", "Key/1", ...), NOT
          # from a bare "Key=value". A plain
          # `HiddenNotifications=wayland-diagnose-kde` parses to an empty list
          # and does nothing. The correct INI form is:
          #   HiddenNotifications=
          #   HiddenNotifications/0=wayland-diagnose-kde
          #
          # NOTE 2: fcitx5 on NixOS does NOT read ~/.config/fcitx5 for its user
          # config. Its StandardPaths PkgConfig user dir resolves (via
          # XDG_CONFIG_DIRS, which contains ~/.config/kdedefaults) to
          # ~/.config/kdedefaults/fcitx5. A file at ~/.config/fcitx5/conf/... is
          # never opened — confirmed by strace. So the suppression must live
          # under kdedefaults/fcitx5, not fcitx5.
          (
            {
              xdg.configFile."kdedefaults/fcitx5/conf/notifications.conf".text = ''
                HiddenNotifications=
                HiddenNotifications/0=wayland-diagnose-kde
              '';
            }
          )
        ];

        nixosModules = [
          inputs.nixos-hardware.nixosModules.framework-12-13th-gen-intel
          inputs.impermanence.nixosModules.default
          ({
            ringofstorms.impermanence = {
              enable = true;
              disk = {
                boot = "/dev/disk/by-uuid/F5C0-5585";
                primary = "/dev/disk/by-uuid/3bfd6e57-5e0f-4742-99e3-e69891ae2431";
                swap = "/dev/disk/by-uuid/ad0311e2-7eb1-47af-bc4b-6311968cbccf";
              };
              encrypted = true;
            };
          })

          inputs.de_plasma.nixosModules.default
          ({
            ringofstorms.dePlasma = {
              enable = true;
              gpu.intel.enable = true;
              sddm.autologinUser = primaryUser;
              wallpapers = [
                ../../hosts/_shared_assets/wallpapers/pixel_neon.png
              ];
            };
          })
          inputs.common.nixosModules.jetbrains_font
          inputs.stt_ime.nixosModules.default
          ({
            ringofstorms.sttIme = {
              enable = true;
              model = "tiny.en";
            };
          })
          inputs.ports.nixosModules.default
          ({ ringofstorms.ports.enable = true; })

          inputs.ros_neovim.nixosModules.default
          ({ ringofstorms-nvim.includeAllRuntimeDependencies = true; })

          inputs.common.nixosModules.boot_systemd
          inputs.common.nixosModules.plymouth
          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.tmux
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.timezone_auto
          inputs.common.nixosModules.tty_caps_esc
          inputs.common.nixosModules.zsh
          inputs.common.nixosModules.rage
          inputs.common.nixosModules.tailnet
          inputs.common.nixosModules.remote_lio_builds

          inputs.common.nixosModules.atuin
          ({
            ringofstorms.atuin = {
              enable = true;
              autologin = {
                enable = true;
                user = primaryUser;
                secretFile = "/var/lib/secrets_manager_hydrated/atuin-key-josh_2026-03-15";
                # Order after sec-agent has rendered the secret. Without this
                # the oneshot races the hydration and fails on switch/boot with
                # "Missing atuin secret" (self-heals via the secret .path unit).
                afterUnits = [ "sec-secrets-ready.service" ];
              };
            };
          })

          (import ./sec-agent.nix { inherit inputs constants; })

          (
            { pkgs, ... }:
            {
              # Allow root deploys via SSH using the nix2nix key (matches
              # joe/lio/h00x). Required so the root flake's `deploy_juni`
              # script can run `nix-env --set` + `switch-to-configuration`
              # on the target.
              users.users.root.openssh.authorizedKeys.keys = [
                fleet.global.sshPubKey
              ];

              environment.shellAliases =
                let
                  no_proxy = "NO_PROXY='h001.net.joshuabell.xyz,*.ts.net,127.0.0.1,localhost,100.64.0.0/10'";
                in
                {
                  "mva" =
                    "${no_proxy} nono run --profile mva-full --allow-cwd --read \"$(git rev-parse --git-common-dir 2>/dev/null || echo /tmp)\" -- /home/josh/projects/mva/target/release/mva";
                  "mva_" = "${no_proxy} /home/josh/projects/mva/target/release/mva";
                };
            }
          )
          ./nono.nix

          inputs.beszel.nixosModules.agent
          ({ beszelAgent.token = "2fb5f0a0-24aa-4044-a893-6d0f916cd063"; })

          ./hardware-configuration.nix
          ./lm-studio.nix
          (import ./impermanence.nix {
            inherit primaryUser;
            impermanence_mod = inputs.impermanence;
          })

          # Host-specific config
          (
            { pkgs, ... }:
            {
              nixpkgs.config.permittedInsecurePackages = [
                "electron-39.8.10"
              ];
              environment.systemPackages = with pkgs; [
                # On-screen keyboard for tablet mode (see hmModules override).
                maliit-keyboard
                qdirstat
                vlc
                google-chrome
                firefox
                jellyfin-media-player
                ttyd
                vesktop
                spotify
                element-desktop
                bitwarden-desktop
              ];
            }
          )
        ];
      };
    };
}
