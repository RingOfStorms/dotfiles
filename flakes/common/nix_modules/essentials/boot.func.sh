_nix_boot_clean_usage() {
  cat <<'EOF'
usage:
  nix-boot-clean [--keep N] [--flake PATH] [--host NAME] [-h|--help]

Cleans /boot and the nix store, then rebuilds the boot loader entries.

What it does (in order):
  1. nh clean all --keep N         (prune nix profiles + store)
  2. prune /boot/loader/entries    (keep last N, never touch windows.conf)
  3. nixos-rebuild boot --flake    (re-sync /boot from surviving generations)

options:
  --keep N        How many generations / loader entries to keep. Default: 5.
  --flake PATH    Flake directory to rebuild from.
                  Defaults to: $FLAKE, then ~/.config/nixos-config.
                  Prompts if neither exists.
  --host NAME     Flake host attribute. Default: $(hostname).
  -h, --help      Show this help.
EOF
}

nix-boot-clean() {
  local keep=5
  local flake=""
  local host=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --keep)
        if [ -z "${2:-}" ]; then
          echo "Error: --keep requires a value" >&2
          return 1
        fi
        keep="$2"
        shift 2
        ;;
      --flake)
        if [ -z "${2:-}" ]; then
          echo "Error: --flake requires a value" >&2
          return 1
        fi
        flake="$2"
        shift 2
        ;;
      --host)
        if [ -z "${2:-}" ]; then
          echo "Error: --host requires a value" >&2
          return 1
        fi
        host="$2"
        shift 2
        ;;
      -h|--help)
        _nix_boot_clean_usage
        return 0
        ;;
      *)
        echo "Error: unknown argument: $1" >&2
        _nix_boot_clean_usage >&2
        return 1
        ;;
    esac
  done

  if ! [[ "$keep" =~ ^[0-9]+$ ]] || [ "$keep" -lt 1 ]; then
    echo "Error: --keep must be a positive integer (got: $keep)" >&2
    return 1
  fi

  # Resolve flake path: --flake arg > $FLAKE env > ~/.config/nixos-config > prompt
  if [ -z "$flake" ]; then
    if [ -n "${FLAKE:-}" ] && [ -f "$FLAKE/flake.nix" ]; then
      flake="$FLAKE"
    elif [ -f "$HOME/.config/nixos-config/flake.nix" ]; then
      flake="$HOME/.config/nixos-config"
    else
      echo "Could not locate a flake.nix at \$FLAKE or ~/.config/nixos-config" >&2
      printf 'Enter path to flake directory: ' >&2
      read -r flake
      if [ -z "$flake" ] || [ ! -f "$flake/flake.nix" ]; then
        echo "Error: '$flake' does not contain a flake.nix" >&2
        return 1
      fi
    fi
  else
    if [ ! -f "$flake/flake.nix" ]; then
      echo "Error: --flake '$flake' does not contain a flake.nix" >&2
      return 1
    fi
  fi

  if [ -z "$host" ]; then
    host="$(hostname)"
  fi

  # Need root for /boot writes and nixos-rebuild boot.
  local sudo=""
  if [ "$(id -u)" -ne 0 ]; then
    sudo="sudo"
  fi

  echo "==> nix-boot-clean: keep=$keep flake=$flake host=$host"
  echo

  echo "==> [1/3] nh clean all --keep $keep"
  if ! nh clean all --keep "$keep"; then
    echo "Error: nh clean failed" >&2
    return 1
  fi
  echo

  echo "==> [2/3] pruning /boot/loader/entries (keeping last $keep, preserving windows.conf)"
  # Sort by mtime ascending; head -n -N drops the newest N (keeps them).
  local entries_to_remove
  entries_to_remove="$($sudo find /boot/loader/entries -maxdepth 1 -type f ! -name 'windows.conf' -printf '%T@ %p\n' \
    | sort -n \
    | head -n "-$keep" \
    | cut -d' ' -f2-)"
  if [ -n "$entries_to_remove" ]; then
    echo "$entries_to_remove" | while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      echo "  rm $entry"
      $sudo rm -- "$entry"
    done
  else
    echo "  (nothing to remove)"
  fi
  echo

  echo "==> [3/3] nixos-rebuild boot --flake $flake#$host"
  if ! $sudo nixos-rebuild boot --flake "$flake#$host"; then
    echo "Error: nixos-rebuild boot failed" >&2
    return 1
  fi
  echo

  echo "==> done. /boot usage:"
  df -h /boot
}
