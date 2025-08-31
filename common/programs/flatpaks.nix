{
  config,
  lib,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "programs"
    "flatpaks"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "flatpaks";
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "List of Flatpak package names to install.";
      };
    };

  config = lib.mkIf cfg.enable {
    services.flatpak = {
      enable = true;
      packages = cfg.packages;
      overrides = {
        global = {
          Context.sockets = [
            "wayland"
            "fallback-x11"
          ];

          Environment = {
            XCURSOR_PATH = "/run/host/user-share/icons:/run/host/share/icons";
            GTK_THEME = "Adwaita:dark";
            # Force wayland as much as possible.
            ELECTRON_OZONE_PLATFORM_HINT = "auto"; # or 'auto'
            GTK_USE_PORTAL = "1";
            OZONE_PLATFORM = "wayland";
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
}
