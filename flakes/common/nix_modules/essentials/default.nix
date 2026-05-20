{
  lib,
  pkgs,
  ...
}:
with lib;
{
  security.sudo = {
    extraConfig = ''
      Defaults lecture="never"
    '';
  };

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
    parted
    fio
    moreutils

    # `rmrec <name> [name...]` - recursively find and delete dirs/files by
    # name under CWD (e.g. `rmrec node_modules dist target .direnv`).
    # Lists matches first and prompts for confirmation. Uses -prune so it
    # doesn't descend into matched dirs. chmods u+w first so read-only
    # files (git objects, etc.) don't block rm.
    (pkgs.writeShellScriptBin "rmrec" ''
      set -euo pipefail
      if [ $# -lt 1 ]; then
        echo "usage: rmrec <name> [name...]" >&2
        echo "  recursively finds and deletes dirs/files matching any name under CWD" >&2
        exit 1
      fi
      args=( '(' )
      first=1
      for n in "$@"; do
        if [ $first -eq 1 ]; then first=0; else args+=( -o ); fi
        args+=( -name "$n" )
      done
      args+=( ')' )

      echo "rmrec: scanning $(pwd) for: $*" >&2
      matches=$(${pkgs.findutils}/bin/find . "''${args[@]}" -prune -print)
      if [ -z "$matches" ]; then
        echo "rmrec: nothing to remove" >&2
        exit 0
      fi
      echo "$matches"
      count=$(printf '%s\n' "$matches" | wc -l)
      printf 'rmrec: delete %s entries? [y/N] ' "$count" >&2
      read -r ans
      case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "rmrec: aborted" >&2; exit 1 ;;
      esac
      printf '%s\n' "$matches" | xargs -d '\n' -r chmod -R u+w 2>/dev/null || true
      printf '%s\n' "$matches" | xargs -d '\n' -r rm -rf
      echo "rmrec: done" >&2
    '')
  ];

  environment.shellAliases = {
    n = "nvim";
    nn = "nvim --headless '+SessionDelete' +qa > /dev/null 2>&1 && nvim";
    bat = "bat --theme Coldark-Dark";
    cat = "bat --pager=never -p";

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

    speedtest_internet = "speedtest-cli";
  };

  environment.shellInit = lib.concatStringsSep "\n\n" [
    (builtins.readFile ./unix_utils.func.sh)
    (builtins.readFile ./nixpkg.func.sh)
    (builtins.readFile ./envrc-import.func.sh)
    (builtins.readFile ./flake.func.sh)
    (builtins.readFile ./boot.func.sh)
  ];
}
