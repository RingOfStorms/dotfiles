{
  config,
  lib,
  pkgs,
  ...
}:
let
  ccfg = import ../../config.nix;
  cfg_path = [ ccfg.custom_config_key "desktopEnvironment" "cosmic" ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
in
with lib;
{
  options = {}
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "COSMIC desktop environment (System76)";
      terminalCommand = mkOption {
        type = lib.types.str;
        default = "foot";
        description = "The terminal command to use.";
      };
    };

  config = lib.mkIf cfg.enable {
    services.greetd = {
      enable = true;
      vt = 2;
      # settings.default_session = {
      #   command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --remember --remember-session --cmd '${pkgs.dbus}/bin/dbus-run-session ${pkgs.cosmic}/bin/cosmic-session'";
      #   user = "greeter";
      # };
    };

    # Caps Lock as Escape for console/tty
    console.useXkbConfig = true;
    services.xserver.xkb = {
      layout = "us";
      options = "caps:escape";
    };

    environment.systemPackages = with pkgs; [
      wl-clipboard
      wofi
      btop
    ];

    xdg.portal.enable = true;

    environment.sessionVariables = {
      NIXOS_OZONE_WL = "1";
      GTK_THEME = "Adwaita:dark";
    };

    qt = { enable = true; platformTheme = "gtk2"; style = "adwaita-dark"; };
    hardware.graphics.enable = true;
  };
}
