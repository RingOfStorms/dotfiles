_flake_usage() {
  cat <<'EOF'
usage:
  flake update                 pick inputs via fzf
  flake update <name...>       update specific inputs
  flake update -a|--all        update all inputs
EOF
}

_flake_root() {
  local dir
  dir="$(pwd -P)"

  while [ "$dir" != "/" ]; do
    if [ -f "$dir/flake.nix" ]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  return 1
}

flake() {
  local subcommand
  subcommand="${1:-}"

  case "$subcommand" in
    update)
      shift

      local root
      root="$(_flake_root)" || {
        echo "Error: not in a flake directory (missing flake.nix)" >&2
        return 1
      }

      local lock_file
      lock_file="$root/flake.lock"

      local all
      all=0

      while [ $# -gt 0 ]; do
        case "$1" in
          -a|--all)
            all=1
            shift
            ;;
          -h|--help)
            _flake_usage
            return 0
            ;;
          --)
            shift
            break
            ;;
          -*)
            echo "Error: unknown flag: $1" >&2
            _flake_usage >&2
            return 1
            ;;
          *)
            break
            ;;
        esac
      done

      if [ "$all" -eq 1 ]; then
        (cd "$root" && nix flake update)
        return $?
      fi

      if [ $# -gt 0 ]; then
        echo "Updating inputs: $*"
        (cd "$root" && nix flake update "$@")
        return $?
      fi

      if [ ! -f "$lock_file" ]; then
        echo "Error: missing $lock_file" >&2
        echo "Run: (cd \"$root\" && nix flake lock)" >&2
        return 1
      fi

      if ! command -v fzf >/dev/null 2>&1; then
        echo "Error: fzf not found" >&2
        return 1
      fi

      if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq not found" >&2
        return 1
      fi

      local selected
      selected="$(
        jq -r '.nodes.root.inputs | keys[]' "$lock_file" | \
          fzf --multi \
            --prompt='flake update > ' \
            --header='TAB to select, ENTER to update'
      )"

      if [ -z "$selected" ]; then
        echo "No inputs selected"
        return 1
      fi

      local inputs
      inputs=()

      while IFS= read -r input; do
        [ -z "$input" ] && continue
        inputs+=("$input")
      done <<< "$selected"

      echo "Updating inputs: ${inputs[*]}"
      (cd "$root" && nix flake update "${inputs[@]}")
      return $?
      ;;

    -h|--help|help|"")
      _flake_usage
      ;;

    *)
      echo "Error: unknown subcommand: $subcommand" >&2
      _flake_usage >&2
      return 1
      ;;
  esac
}
