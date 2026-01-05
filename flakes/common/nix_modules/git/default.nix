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
    bs = "branching_setup";
    gcp = "gcpropose";
  };

  environment.shellInit = lib.concatStringsSep "\n\n" [
    (builtins.readFile ./utils.func.sh)
    (builtins.readFile ./branch.func.sh)
    (builtins.readFile ./branchd.func.sh)
    (builtins.readFile ./link_ignored.func.sh)
    (builtins.readFile ./branching_setup.func.sh)
    (builtins.readFile ./gcpropose.func.sh)
  ];
}
