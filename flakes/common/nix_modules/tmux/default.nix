{
  lib,
  pkgs,
  ...
}:
{
  environment.systemPackages = [
    pkgs.tmux
  ];

  environment.shellAliases = {
    tat = "tmux attach-session";
    t = "tmux";
  };

  environment.shellInit = lib.concatStringsSep "\n\n" [
    (builtins.readFile ./tmux_helpers.sh)
  ];
}
