{
  inputs = {
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";
  };

  outputs =
    {
      nix-flatpak,
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
          {
            imports = [
              nix-flatpak.nixosModules.nix-flatpak
            ];
            config = {
              services.flatpak = {
                enable = true;
                overrides = {
                  global = {
                    Context.sockets = [
                      "wayland"
                      "x11"
                    ];
                    Context.devices = [ "dri" ]; # allow GPU access if desired
                    Environment = {
                      XCURSOR_PATH = "/run/host/user-share/icons:/run/host/share/icons";
                      GTK_THEME = "Adwaita:dark";
                      # Force wayland as much as possible.
                      ELECTRON_OZONE_PLATFORM_HINT = "auto"; # or 'auto'
                      GTK_USE_PORTAL = "1";
                      OZONE_PLATFORM = "wayland";
                      QT_QPA_PLATFORM = "xcb"; # force XCB for Flatpaks (XWayland)
                    };
                  };
                  "org.signal.Signal" = {
                    Environment = {
                      SIGNAL_PASSWORD_STORE = "gnome-libsecret";
                    };
                    Context = {
                      sockets = [
                        "xfg-settings"
                      ];
                    };
                  };
                  "com.google.Chrome" = {
                    Environment = {
                      CHROME_EXTRA_ARGS = "--enable-features=WaylandWindowDecorations --ozone-platform-hint=auto";
                    };
                  };
                };
              };
            };
          };
      };
    };
}
