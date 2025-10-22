{
  lib,
  pkgs,
  ...
}:
with lib;
{
  environment.systemPackages = with pkgs; [
    git
  ];

  environment.shellAliases = {
    # git
    status = "git status";
    diff = "git diff";
    branches = "git branch -a";
    gcam = "git commit -a -m";
    gcm = "git commit -m";
    stashes = "git stash list";
    bd = "branch default";
    li = "link_ignored";
    bx = "branchdel";
    b = "branch";
  };

  environment.shellInit = lib.concatStringsSep "\n\n" [
    (builtins.readFile ./utils.func.sh)
    (builtins.readFile ./branch.func.sh)
    (builtins.readFile ./branchd.func.sh)
    (builtins.readFile ./link_ignored.func.sh)
  ];
}
