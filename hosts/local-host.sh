#!/usr/bin/env bash
# local-host.sh — evaluate/build/switch a host flake against the LIVE working
# tree of this repo's sub-flakes, without touching flake.nix or flake.lock.
#
# WHY
#   Every host flake pins its in-repo inputs (common, containers, impermanence,
#   fleet-agent, ...) to a git URL + flake.lock revision on purpose: a machine
#   keeps building from the version it last locked, so breaking changes in the
#   latest `common` never reach it until you run
#   `./hosts/update-all-host-flakes.sh common` (or `nix flake update common`
#   in that host). That pinning is the design; this script does not change it.
#
#   To try uncommitted/unpushed changes before you push and update locks, this
#   script finds every input a host declares whose URL points into this repo
#   (`git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=<subdir>`) and
#   passes `--override-input <name> path:<repo>/<subdir>` for each. Overrides
#   apply only to that one command; the lock file is never written
#   (`--no-write-lock-file`).
#
# USAGE
#   hosts/local-host.sh <host>  <cmd> [extra args passed through]
#   hosts/local-host.sh --all   <cmd> [extra args]      (every host flake)
#
#   <host> is a fleet name (h001, lio, ...) or a path to the host flake dir
#   (hosts/oracle/o002). Commands:
#     flags   print the --override-input flags (paste into any nix command)
#     inputs  list "<input> -> <local path>" for the host
#     eval    eval nixosConfigurations.<host>.config.system.build.toplevel.drvPath
#     build   nix build the system closure (./result-<host>)
#     dry     nix build --dry-run (what would be built/fetched)
#     test | switch | boot | build-vm
#             sudo nixos-rebuild <cmd> --flake <dir>#<host> with the overrides
#
# EXAMPLES
#   hosts/local-host.sh h003 eval              # does h003 evaluate with my edits?
#   hosts/local-host.sh --all eval             # catch breakage across the fleet
#   hosts/local-host.sh lio switch             # run lio on the working tree
#   nix build $(hosts/local-host.sh lio flags) ./hosts/lio#nixosConfigurations.lio.config.system.build.toplevel
#   nh os switch ./hosts/lio -- $(hosts/local-host.sh lio flags)
#
# NOTES
#   - `path:` copies the sub-flake dir into the store as-is, so uncommitted
#     and untracked files are included.
#   - Inputs NOT from this repo (nixpkgs, home-manager, ros_neovim, ...) keep
#     their locked versions.
#   - A host's own files (hosts/<host>/*.nix, ../fleet.nix) are always read
#     from the working tree anyway, since the host flake is built from its dir.
#   - Env LOCAL_HOST_EXTRA_INPUTS="name=subdir ..." adds/overrides mappings.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOSTS="$REPO/hosts"
REPO_URL_RE='ringofstorms\/dotfiles'

usage() {
  sed -n '2,/^set -uo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
  exit "${1:-2}"
}

# host name or dir -> "<abs dir>"
host_dir() {
  local h="$1"
  if [ -f "$h/flake.nix" ]; then (cd "$h" && pwd); return; fi
  if [ -f "$REPO/$h/flake.nix" ]; then (cd "$REPO/$h" && pwd); return; fi
  if [ -f "$HOSTS/$h/flake.nix" ]; then echo "$HOSTS/$h"; return; fi
  local d
  d="$(find "$HOSTS" -mindepth 2 -maxdepth 3 -type d -name "$h" -exec test -f '{}/flake.nix' ';' -print -quit)"
  [ -n "$d" ] && { echo "$d"; return; }
  echo "local-host: no host flake for '$h'" >&2
  return 1
}

# nixosConfigurations attr name: the single one the flake defines, else dir name.
host_attr() {
  local dir="$1" names
  names="$(nix eval --no-write-lock-file --json "path:$REPO?dir=${dir#"$REPO"/}#nixosConfigurations" \
    --apply builtins.attrNames 2>/dev/null | tr -d '[]"' | tr ',' ' ')"
  set -- $names
  if [ $# -eq 1 ]; then echo "$1"; else basename "$dir"; fi
}

# "<input> <subdir>" for every uncommented input URL pointing into this repo.
local_inputs() {
  local dir="$1"
  perl -ne '
    next if /^\s*#/;
    if (/^\s*"?([A-Za-z0-9_-]+)"?(?:\.url)?\s*=\s*"git\+[^"]*'"$REPO_URL_RE"'[^"]*[?&]dir=([^"&]+)/) { print "$1 $2\n" }
    elsif (/^\s*"?([A-Za-z0-9_-]+)"?(?:\.url)?\s*=\s*"git\+[^"]*'"$REPO_URL_RE"'(?:\.git)?"/) { print "$1 .\n" }
  ' "$dir/flake.nix" | sort -u
  local kv
  for kv in ${LOCAL_HOST_EXTRA_INPUTS:-}; do echo "${kv%%=*} ${kv#*=}"; done
}

flags() {
  local dir="$1" name sub
  while read -r name sub; do
    [ -n "$name" ] || continue
    if [ ! -f "$REPO/$sub/flake.nix" ]; then
      echo "local-host: $name -> $sub has no flake.nix in the working tree, skipped" >&2
      continue
    fi
    printf -- '--override-input %s path:%s ' "$name" "$REPO/$sub"
  done < <(local_inputs "$dir")
}

run_one() {
  local h="$1" cmd="$2"
  shift 2
  local dir attr
  dir="$(host_dir "$h")" || return 1
  # shellcheck disable=SC2207
  local fl=($(flags "$dir"))
  case "$cmd" in
    flags) echo "${fl[*]} --no-write-lock-file"; return ;;
    inputs)
      local name sub
      while read -r name sub; do echo "$name -> $REPO/$sub"; done < <(local_inputs "$dir")
      return
      ;;
  esac
  attr="$(host_attr "$dir")"
  # Host flakes import ../fleet.nix etc., so the flake must be the whole repo
  # tree with dir= pointing at the host (a bare path:<hostdir> cannot see ..).
  local fref="path:$REPO?dir=${dir#"$REPO"/}"
  local ref="$fref#nixosConfigurations.$attr"
  case "$cmd" in
    eval)
      nix eval --no-write-lock-file "${fl[@]}" --raw "$ref.config.system.build.toplevel.drvPath" "$@" && echo
      ;;
    build)
      nix build --no-write-lock-file "${fl[@]}" -o "result-$attr" "$ref.config.system.build.toplevel" "$@"
      ;;
    dry)
      nix build --no-write-lock-file "${fl[@]}" --dry-run "$ref.config.system.build.toplevel" "$@"
      ;;
    test | switch | boot | build-vm | dry-build | dry-activate)
      local sudo=()
      case "$cmd" in build-vm | dry-build) ;; *) [ "$(id -u)" = 0 ] || sudo=(sudo) ;; esac
      "${sudo[@]}" nixos-rebuild "$cmd" --flake "$fref#$attr" --no-write-lock-file "${fl[@]}" "$@"
      ;;
    *)
      echo "local-host: unknown command '$cmd'" >&2
      usage
      ;;
  esac
}

[ $# -ge 1 ] || usage
case "$1" in -h | --help) usage 0 ;; esac
[ $# -ge 2 ] || usage

if [ "$1" = "--all" ]; then
  cmd="$2"
  shift 2
  case "$cmd" in test | switch | boot) echo "local-host: refusing '$cmd' for --all" >&2; exit 2 ;; esac
  mapfile -t DIRS < <((cd "$REPO" && find hosts -name flake.nix -not -path "*/.*" -printf "$REPO/%h\n") | sort)
  fail=()
  for d in "${DIRS[@]}"; do
    rel="${d#"$REPO"/}"
    printf '== %s\n' "$rel"
    run_one "$d" "$cmd" "$@" || fail+=("$rel")
  done
  echo
  if [ ${#fail[@]} -gt 0 ]; then
    echo "FAILED (${#fail[@]}/${#DIRS[@]}): ${fail[*]}"
    exit 1
  fi
  echo "OK (${#DIRS[@]} hosts)"
  exit 0
fi

run_one "$@"
