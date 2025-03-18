{
  config,
  lib,
  pkgs,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "programs"
    "rustDev"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "rust development tools";
      repl = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable the evcxr repl for `rust` command.";
      };
      # TODO?
      # channel = lib.mkOption {
      #   type = lib.types.str;
      #   default = "stable";
      #   description = "The Rust release channel to use (e.g., stable, beta, nightly).";
      # };
      # version = lib.mkOption {
      #   type = lib.types.str;
      #   default = "latest";
      #   description = "The specific version of Rust to use. Use 'latest' for the latest stable release.";
      # };
    };

  config = lib.mkIf cfg.enable {
    environment.systemPackages =
      with pkgs;
      [
        rustup
        gcc
      ]
      ++ (if cfg.repl then [ pkgs.evcxr ] else [ ]);

    environment.shellAliases = lib.mkIf cfg.repl {
      rust = "evcxr";
    };
  };

}
