{
  lib,
  pkgs,
  ...
}:
with lib;
{
  config = {
    environment.systemPackages = with pkgs; [
      # Basics
      vim
      nano
      wget
      curl
      jq
      fastfetch
      bat
      htop
      unzip
      git
      fzf
      ripgrep
      lsof
      killall
      hdparm
      speedtest-cli
      lf
    ];

    environment.shellAliases = {
      n = "nvim";
      nn = "nvim --headless '+SessionDelete' +qa > /dev/null 2>&1 && nvim";
      bat = "bat --theme Coldark-Dark";
      cat = "bat --pager=never -p";
      # TODO this may not be needed now that I am using `nh` clean mode (see /hosts/_common/configuration.nix#programs.nh)
      nix-boot-clean = "find '/boot/loader/entries' -type f ! -name 'windows.conf' | head -n -4 | xargs -I {} rm {}; nix store gc; nixos-rebuild boot; echo; df";
      ndr = "nix-direnv-reload";

      # general unix
      date_compact = "date +'%Y%m%d'";
      date_short = "date +'%Y-%m-%d'";
      ls = "ls --color -Gah";
      ll = "ls --color -Galhtr";
      lss = "du --max-depth=0 -h {.,}* 2>/dev/null | sort -hr";
      psg = "ps aux | head -n 1 && ps aux | grep -v 'grep' | grep";
      cl = "clear";

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

      # ripgrep
      rg = "rg --no-ignore";
      rgf = "rg --files --glob '!/nix/store/**' 2>/dev/null | rg";
    };

    environment.shellInit = lib.concatStringsSep "\n\n" [
      (builtins.readFile ./common.sh)
      (builtins.readFile ./tmux_helpers.sh)
      (builtins.readFile ./branch.func.sh)
      (builtins.readFile ./branchd.func.sh)
      (builtins.readFile ./link_ignored.func.sh)
    ];
  };
}
