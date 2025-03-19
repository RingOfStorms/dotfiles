{
  config,
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
    ];

    environment.shellAliases = {
      n = "nvim";
      nn = "nvim --headless '+SessionDelete' +qa > /dev/null 2>&1 && nvim";
      bat = "bat --theme Coldark-Dark";
      cat = "bat --pager=never -p";
      # TODO this may not be needed now that I am using `nh` clean mode (see /hosts/_common/configuration.nix#programs.nh)
      nix-boot-clean = "find '/boot/loader/entries' -type f ! -name 'windows.conf' | head -n -4 | xargs -I {} rm {}; nix store gc; nixos-rebuild boot; echo; df";

      # general unix
      date_compact = "date +'%Y%m%d'";
      date_short = "date +'%Y-%m-%d'";
      ls = "ls --color -Gah";
      ll = "ls --color -Galh";
      lss = "du --max-depth=0 -h * 2>/dev/null | sort -hr";
      psg = "ps aux | head -n 1 && ps aux | grep -v 'grep' | grep";
      cl = "clear";

      # git
      stash = "git stash";
      pop = "git stash pop";
      branch = "git checkout -b";
      status = "git status";
      diff = "git diff";
      branches = "git branch -a";
      gcam = "git commit -a -m";
      gcm = "git commit -m";
      stashes = "git stash list";

      # ripgrep
      rg = "rg --no-ignore";
      rgf = "rg --files 2>/dev/null | rg";
    };

    environment.shellInit = builtins.readFile ./common.sh;
  };
}
