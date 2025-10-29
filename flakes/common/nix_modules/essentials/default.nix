{
  lib,
  pkgs,
  ...
}:
with lib;
{
  environment.systemPackages = with pkgs; [
    # Essentials
    vim
    nano
    wget
    curl
    traceroute
    dig
    fastfetch
    jq
    bat
    htop
    unzip
    fzf
    ripgrep
    lsof
    killall
    speedtest-cli
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
    time_compact = "date +'%Y%m%d%H%M%'";
    time_short = "date +'%Y-%m-%dT%H:%M:%S'";
    ls = "ls --color -Gah";
    ll = "ls --color -Galhtr";
    lss = "du --max-depth=0 -h {.,}* 2>/dev/null | sort -hr";
    psg = "ps aux | head -n 1 && ps aux | grep -v 'grep' | grep";

    # ripgrep
    rg = "rg --no-ignore";
    rgf = "rg --files --glob '!/nix/store/**' 2>/dev/null | rg";
  };

  environment.shellInit = lib.concatStringsSep "\n\n" [
    (builtins.readFile ./unix_utils.func.sh)
    (builtins.readFile ./nixpkg.func.sh)
    (builtins.readFile ./envrc-import.func.sh)
  ];
}
