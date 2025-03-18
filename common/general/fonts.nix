{
  pkgs,
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
in
{
  config = {
    fonts.packages = [ jetbrainsMonoFont ];
  };
}
