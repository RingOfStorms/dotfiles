tmux_window () {
  cmd=${1:-}
  case "${cmd}" in
    rename)
      if [ -z "${2:-}" ]; then
        tmux setw automatic-rename
      else
        tmux rename-window "$2"
      fi
      ;;
    get)
      printf '%s' "$(tmux display-message -p '#W')"
      ;;
    status)
      out="$(tmux show-window-options automatic-rename 2>/dev/null || true)"
      if printf '%s' "$out" | grep -q 'automatic-rename on'; then
        printf 'auto'
      elif printf '%s' "$out" | grep -q 'automatic-rename off'; then
        printf 'manual'
      else
        # If tmux returns nothing (option not set), default to auto
        if [ -z "$out" ]; then
          printf 'auto'
        else
          return 1
        fi
      fi
      ;;
    *)
      printf 'Usage: tmux_window {rename [NAME]|get|status}\n' >&2
      return 2
      ;;
  esac
}
