{
  inputs = {
    # TODO requires home-manager module to be on the system as well, byohm
    hyprland = {
      url = "github:hyprwm/Hyprland";
    };
  };

  outputs =
    {
      hyprland,
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
            pkgs-unstable = hyprland.inputs.nixpkgs.legacyPackages.${pkgs.system};
            cfg = config.mods.de_hyprland;
          in
          with lib;
          {
            options.mods.de_hyprland = {
              users = mkOption {
                type = types.listOf types.str;
                description = "Users to apply cosmic DE settings to.";
                default = (
                  lib.optionals (config.mods.common.primaryUser != null) [ config.mods.common.primaryUser ]
                );
              };
              amd = mkEnableOption "Enable AMD graphics drivers.";
              nvidia = mkEnableOption "Enable NVIDIA graphics drivers.";
            };

            imports = [
              # cosmic.nixosModules.default
            ];

            config = {
              # Polkit required
              security.polkit.enable = true;
              # amd drivers
              boot.initrd.kernelModules = mkIf cfg.amd [ "amdgpu" ];
              systemd.tmpfiles.rules = mkIf cfg.amd [
                "L+    /opt/rocm/hip   -    -    -     -    ${pkgs.rocmPackages.clr}"
              ];
              hardware.graphics.extraPackages = mkIf cfg.amd (
                with pkgs;
                [
                  rocmPackages.clr.icd
                ]
              );

              services.xserver = {
                enable = true;
                xkb.layout = "us";
                # videosDrivers = ["nvidia"];
                vidoesDrivers = mkIf cfg.nvidia [ "nvidia" ];
                videoDrivers = mkIf cfg.amd [ "amdgpu" ];
                displayManager.gdm = {
                  enable = true;
                  wayland = true;
                };
              };
              xdg = {
                autostart.enable = true;
                portal = {
                  enable = true;
                  extraPortals = [
                    pkgs.xdg-desktop-portal
                    pkgs.xdg-desktop-portal-gtk
                  ];
                };
              };
              security = {
                pam.services.swaylock = {
                  text = ''
                    auth include login
                  '';
                };
              };
              programs = {
                hyprland = {
                  enable = true;
                  # nvidiaPatches = true;
                  xwayland.enable = true;
                  # set the flake package
                  package = hyprland.packages.${pkgs.system}.hyprland;
                  # make sure to also set the portal package, so that they are in sync
                  portalPackage = hyprland.packages.${pkgs.system}.xdg-desktop-portal-hyprland;
                };
                waybar = {
                  enable = true;
                };
                thunar = {
                  enable = true;
                };
              };
              environment.systemPackages = with pkgs; [
                clinfo # TODO only in amd
                # required
                dconf
                xwayland

                kitty
                swaylock
                swayidle
                xdg-utils
                xdg-desktop-portal-hyprland
                xdg-desktop-portal
                xdg-desktop-portal-gtk
              ];

              environment.sessionVariables = {
                # If cursor becomes invisible
                # WLR_NO_HARDWARE_CURSORS = "1";
                # Optional, hint Electron apps to use Wayland:
                NIXOS_OZONE_WL = "1";

                XDG_SESSION_TYPE = "wayland";
                XDG_CURRENT_DESKTOP = "Hyprland";
                XDG_SESSION_DESKTOP = "Hyprland";
              };

              # FPS drops in games or programs like Blender on stable NixOS when using the Hyprland flake, it is most likely a mesa version mismatch between your system and Hyprland
              hardware = {
                graphics = {
                  enable = true;
                  # nvidia.modsettings.enable = true;
                  package = pkgs-unstable.mesa.drivers;
                  # if you also want 32-bit support (e.g for Steam)
                  enable32Bit = true;
                  package32 = pkgs-unstable.pkgsi686Linux.mesa.drivers;
                };
                # TODO nvidia...
              };

              # Config TODO come up with a non home-manager way to do this. I dont want this flake to require home-manager from somewhere else to exist
              home-manager.users = listToAttrs (
                map (name: {
                  inherit name;
                  value = {
                    programs.kitty.enable = true; # required for the default Hyprland config

                    wayland.windowManager.hyprland = {
                      enable = true;
                      xwayland.enable = true;
                      package = hyprland.packages.${pkgs.system}.hyprland;

                      # plugins = [
                      #   inputs.hyprland-plugins.packages.${pkgs.stdenv.hostPlatform.system}.hyprbars
                      #   "/absolute/path/to/plugin.so"
                      # ];
                      settings = {
                        "$mod" = "SUPER";
                        bind =
                          [
                            "$mod, F, exec, firefox"
                            ", Print, exec, grimblast copy area"
                          ]
                          ++ (
                            # workspaces
                            # binds $mod + [shift +] {1..9} to [move to] workspace {1..9}
                            builtins.concatLists (
                              builtins.genList (
                                i:
                                let
                                  ws = i + 1;
                                in
                                [
                                  "$mod, code:1${toString i}, workspace, ${toString ws}"
                                  "$mod SHIFT, code:1${toString i}, movetoworkspace, ${toString ws}"
                                ]
                              ) 9
                            )
                          );
                      };
                      # Programs don’t work in systemd services, but do on the terminal fix
                      systemd = {
                        enable = true;
                        variables = [ "--all" ];
                      };
                    };

                    # Fixing problems with themes  TODO use this?
                    # home.pointerCursor = {
                    #   gtk.enable = true;
                    #   # x11.enable = true;
                    #   package = pkgs.bibata-cursors;
                    #   name = "Bibata-Modern-Classic";
                    #   size = 16;
                    # };
                    #
                    # gtk = {
                    #   enable = true;
                    #
                    #   theme = {
                    #     package = pkgs.flat-remix-gtk;
                    #     name = "Flat-Remix-GTK-Grey-Darkest";
                    #   };
                    #
                    #   iconTheme = {
                    #     package = pkgs.gnome.adwaita-icon-theme;
                    #     name = "Adwaita";
                    #   };
                    #
                    #   font = {
                    #     name = "Sans";
                    #     size = 11;
                    #   };
                    # };
                  };
                }) cfg.users
              );
            };
          };
      };
    };
}
