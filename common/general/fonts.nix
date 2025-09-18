{
  pkgs,
  lib,
  config,
  ...
}:
let
  hasNewJetbrainsMono =
    if builtins.hasAttr "nerd-fonts" pkgs then
      builtins.hasAttr "jetbrains-mono" pkgs."nerd-fonts"
    else
      false;

  jetbrainsMonoFont =
    if hasNewJetbrainsMono then
      pkgs.nerd-fonts.jetbrains-mono
    else
      (pkgs.nerdfonts.override { fonts = [ "JetBrainsMono" ]; });

  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "general"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      jetbrainsMonoFont = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable jetbrains mono font";
      };
      japaneseFonts = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable japanese fonts";
      };
    };

  config = {
    fonts.packages =
      lib.optionals cfg.jetbrainsMonoFont [
        jetbrainsMonoFont
      ]
      ++ lib.optionals cfg.japaneseFonts (
        with pkgs;
        [
          ipafont
          kochi-substitute
          noto-fonts-cjk-sans # Or another CJK font
        ]
      );

    fonts.fontconfig.enable = true;
  };
}
