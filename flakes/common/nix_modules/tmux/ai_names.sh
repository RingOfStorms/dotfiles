# tmux-ai-names: name tmux windows and panes with the fast LLM tier.
#
# One background instance per tmux server, started from tmux.conf. Every TICK
# seconds each window is fingerprinted from its panes' cwd, git branch and
# foreground command. When a fingerprint changes and stays stable for one more
# tick, the window's context (plus a short tail of each pane's screen) goes to
# the fast model, which returns a 1-2 word window name (@window_ai_name, shown
# through automatic-rename-format) and pane names (@pane_name, shown in pane
# borders).
#
# Never blocking: tmux only ever reads user options, so if the model is slow or
# h001 is down tmux keeps its normal names (current command) and nothing waits.
# Requests are capped at LLM_MAX_TIME, and repeated failures back off.
#
# Humans win: windows renamed manually (automatic-rename off, `prefix ,`) and
# panes named with `prefix .` (@pane_name_manual) are never renamed.
#   tmux set -g @ai_names off|on             toggle (`prefix A`); off clears AI names
#   tmux set -g @ai_names_model <model>      override the model live
#   tmux set -g @ai_names_reasoning <effort>
# Log: $XDG_RUNTIME_DIR/tmux-ai-names_<socket>.log

readonly TICK=3 MIN_INTERVAL=15 MAX_JOBS=4 SCREEN_LINES=15
readonly S=$'\x1f'
readonly FMT="$S#{window_id}$S#{automatic-rename}$S#{@ai_fp}$S#{session_name}$S#{window_name}$S#{@window_ai_name}$S#{pane_id}$S#{pane_pid}$S#{pane_current_path}$S#{pane_current_command}$S#{pane_active}$S#{@pane_name_manual}$S#{@pane_name}$S#{pane_dead}"
export LLM_MAX_TIME=30

readonly SYSTEM_PROMPT='You label tmux windows and panes so a developer can tell them apart at a glance.
Return only a JSON object: {"window": "<name>", "panes": {"<pane number>": "<name>"}}.
Every name is 1 word, 2 at most, max 16 characters, lowercase except ticket ids (e.g. ABC-123).
Window name: what the window is about. Prefer a ticket id from the git branch, else the project or repo, else the remote host for ssh. Never use generic words like shell, terminal, zsh, home, window.
Pane names: what each pane is doing, so panes in the same window are distinguishable (e.g. server, tests, editor, logs, agent, build, or a host). Do not just repeat the window name.
Keep a current name when it is still accurate. Omit the window key or a pane key when it is locked.'

if [ -z "${TMUX:-}" ]; then
  echo "tmux-ai-names: run inside tmux (it is started from tmux.conf)." >&2
  exit 1
fi

socket=$(tmux display -p '#{socket_path}') || exit 1
state="${XDG_RUNTIME_DIR:-/tmp}/tmux-ai-names${socket//\//_}"
exec 9>"$state.lock"
flock -n 9 || exit 0
exec >"$state.log" 2>&1
self=$(readlink -f "$0")
fail_file="$state.fail"
rm -f "$fail_file"

# fg_cmd <pane-pid> <pane-current-command>: sets fg to the pane's foreground
# command line, or "" when the pane's own shell is idle at a prompt.
fg_cmd() {
  fg=
  local stat rest tpgid
  read -r stat <"/proc/$1/stat" 2>/dev/null || return 0
  rest=${stat##*) }
  read -r _ _ _ _ _ tpgid _ <<<"$rest"
  [ "${tpgid:-0}" -gt 0 ] || return 0
  if [ "$tpgid" = "$1" ]; then
    case $2 in sh | bash | zsh | fish | nu) return 0 ;; esac
  fi
  local -a argv=()
  mapfile -d '' -t argv <"/proc/$tpgid/cmdline" 2>/dev/null
  fg="${argv[*]}"
  fg=${fg//[$'\n\t\x1f']/ }
  fg=${fg:0:200}
}

# Sets g_repo/g_branch for a directory by reading .git directly (no forks).
git_info() {
  g_repo='' g_branch=''
  local d=$1 gitdir='' line head common
  while [ -n "$d" ] && [ "$d" != / ]; do
    if [ -d "$d/.git" ]; then
      gitdir=$d/.git g_repo=${d##*/}
      break
    elif [ -f "$d/.git" ]; then
      read -r line <"$d/.git" 2>/dev/null
      gitdir=${line#gitdir: }
      [[ $gitdir == /* ]] || gitdir=$d/$gitdir
      case $gitdir in
        */worktrees/*)
          common=${gitdir%/worktrees/*}
          common=${common%/.git}
          g_repo=${common##*/}
          g_repo=${g_repo%.git}
          ;;
        *) g_repo=${d##*/} ;;
      esac
      break
    fi
    d=${d%/*}
  done
  [ -n "$gitdir" ] || return 0
  read -r head <"$gitdir/HEAD" 2>/dev/null || return 0
  case $head in
    "ref: refs/heads/"*) g_branch=${head#ref: refs/heads/} ;;
    *) g_branch="detached ${head:0:8}" ;;
  esac
}

# Sets screen to the last SCREEN_LINES non-blank lines of a pane, indented.
screen_tail() {
  screen=
  local -a lines=() keep=()
  local l start
  mapfile -t lines < <(tmux capture-pane -p -J -t "$1" 2>/dev/null)
  for l in "${lines[@]}"; do
    l=${l%"${l##*[![:space:]]}"}
    [ -n "$l" ] && keep+=("    ${l:0:160}")
  done
  start=$((${#keep[@]} > SCREEN_LINES ? ${#keep[@]} - SCREEN_LINES : 0))
  [ ${#keep[@]} -gt 0 ] && screen=$(printf '%s\n' "${keep[@]:start}")
}

# name_window <window-id> <fingerprint-hash> <header> <pane-context> <"n:%id ...">
name_window() {
  local wid=$1 hash=$2 prompt=$3$'\n'$4 entry n reply parsed key name
  local -A pane_of=()
  for entry in $5; do
    n=${entry%%:*}
    pane_of[$n]=${entry#*:}
    screen_tail "${pane_of[$n]}"
    [ -n "$screen" ] && prompt+=$'\n'"Pane $n recent screen:"$'\n'"$screen"$'\n'
  done

  # Model: tmux option @ai_names_model / @ai_names_reasoning, else the module
  # defaults baked in at build time (the server environment goes stale).
  local MODEL_FAST MODEL_FAST_REASONING
  MODEL_FAST=$(tmux show -gqv @ai_names_model)
  MODEL_FAST=${MODEL_FAST:-$AI_NAMES_MODEL}
  MODEL_FAST_REASONING=$(tmux show -gqv @ai_names_reasoning)
  MODEL_FAST_REASONING=${MODEL_FAST_REASONING:-$AI_NAMES_REASONING}

  if ! reply=$(llm_chat fast "$SYSTEM_PROMPT" "$prompt"); then
    # Endpoint down/slow: leave the fingerprint unrecorded so the window is
    # renamed once it is back, and record the failure for the global backoff.
    local fails=0
    [ -r "$fail_file" ] && read -r _ fails <"$fail_file"
    printf '%s %s\n' "$EPOCHSECONDS" "$((fails + 1))" >"$fail_file"
    return 1
  fi
  rm -f "$fail_file"
  parsed=$(printf '%s' "$reply" | sed '/^[[:space:]]*```/d' | jq -r '
    def clean: tostring | gsub("[^A-Za-z0-9 ._/-]"; "") | [splits(" +")]
      | map(select(length > 0)) | .[:2] | join(" ") | .[:24];
    ("w\t" + (.window // "" | clean)),
    ((.panes // {}) | to_entries[] | "\(.key | ltrimstr("pane ") | ltrimstr("Pane "))\t\(.value | clean)")
  ' 2>/dev/null)
  if [ -z "$parsed" ]; then
    printf '%s: unusable reply for %s: %s\n' "$(date -Is)" "$wid" "$reply"
  fi

  # Names are reduced to [A-Za-z0-9 ._/-] above, so they are safe inside tmux
  # double quotes. The lock and on/off checks run inside tmux, atomically with
  # the set, so a manual rename is never overwritten. Setting automatic-rename
  # forces tmux to re-evaluate automatic-rename-format right away.
  while IFS=$'\t' read -r key name; do
    [ -n "$name" ] || continue
    if [ "$key" = w ]; then
      tmux if -F -t "$wid" '#{&&:#{automatic-rename},#{!=:#{@ai_names},off}}' \
        "set -w -t $wid @window_ai_name \"$name\" ; set -w -t $wid automatic-rename on"
    elif [ -n "${pane_of[$key]:-}" ]; then
      tmux if -F -t "${pane_of[$key]}" '#{||:#{@pane_name_manual},#{==:#{@ai_names},off}}' '' \
        "set -p -t ${pane_of[$key]} @pane_name \"$name\""
    fi
  done <<<"$parsed"
  # Recorded even for an unusable reply so a stable window is not re-asked.
  tmux set -w -t "$wid" @ai_fp "$hash"
}

# Drop every AI name so tmux shows its normal names again. Manual pane names
# (@pane_name_manual) and manual window names (automatic-rename off) are kept.
clear_ai_names() {
  local id auto manual
  tmux list-windows -a -F "#{window_id}$S#{automatic-rename}" | while IFS=$S read -r id auto; do
    tmux set -wu -t "$id" @window_ai_name \; set -wu -t "$id" @ai_fp
    # Re-setting automatic-rename makes tmux re-evaluate the name right away.
    [ "$auto" = 1 ] && tmux set -w -t "$id" automatic-rename on
  done
  tmux list-panes -a -F "#{pane_id}$S#{@pane_name_manual}" | while IFS=$S read -r id manual; do
    [ -n "$manual" ] || tmux set -pu -t "$id" @pane_name
  done
}

declare -A pending=() last_try=() job_of=()
enabled=1

while :; do
  # Exit with the server: the lock lives on for a socket path that gets reused.
  enabled_opt=$(tmux show -gqv @ai_names) || exit 0

  # Re-exec into the new build after a system switch.
  new=$(command -v tmux-ai-names) && [ ! "$new" -ef "$self" ] && {
    exec 9>&-
    exec "$new"
  }

  # Global toggle (`tmux set -g @ai_names off`, or `prefix A`).
  if [ "$enabled_opt" = off ]; then
    if [ "$enabled" = 1 ]; then
      enabled=0
      # shellcheck disable=SC2046 # word-splitting the pid list is intended
      kill $(jobs -p) 2>/dev/null
      wait
      clear_ai_names
      pending=() last_try=() job_of=()
      rm -f "$fail_file"
    fi
    sleep "$TICK" || exit 0
    continue
  fi
  enabled=1

  # Backoff while the endpoint is failing: 30s doubling per failure, max 10m.
  if [ -r "$fail_file" ] && read -r fail_at fails <"$fail_file"; then
    backoff=$((30 << (fails > 5 ? 5 : fails - 1)))
    ((backoff > 600)) && backoff=600
    if ((EPOCHSECONDS - fail_at < backoff)); then
      sleep "$TICK" || exit 0
      continue
    fi
  fi

  out=$(tmux list-panes -a -F "$FMT") || exit 0

  declare -A fp=() named=() hdr=() ctx=() unlocked=() count=() wlocked=()
  while IFS=$S read -r _ wid wauto wfp session wname wai pane panepid path cmd active manual pname dead; do
    [ "$dead" = 1 ] && continue
    n=$((${count[$wid]:-0} + 1))
    count[$wid]=$n
    named[$wid]=$wfp

    if [ -z "${hdr[$wid]+x}" ]; then
      hdr[$wid]="Session: $session"
      if [ "$wauto" = 1 ]; then
        hdr[$wid]+=$'\n'"Window: current name \"${wai:-none}\""
        fp[$wid]="auto;"
      else
        hdr[$wid]+=$'\n'"Window: locked by user as \"$wname\""
        fp[$wid]="locked;"
        wlocked[$wid]=1
      fi
    fi

    block="Pane $n"
    [ "$active" = 1 ] && block+=" (active)"
    if [ -n "$manual" ]; then
      ctx[$wid]+=$'\n'"$block: locked by user as \"$pname\""$'\n'
      fp[$wid]+="$pane|locked;"
      continue
    fi

    fg_cmd "$panepid" "$cmd"
    git_info "$path"
    block+=$':\n'"  cwd: ${path/#$HOME/\~}"
    [ -n "$g_repo" ] && block+=$'\n'"  git: repo $g_repo, branch ${g_branch:-unknown}"
    if [ -n "$fg" ]; then
      block+=$'\n'"  running: $fg"
    else
      block+=$'\n'"  running: idle shell ($cmd)"
    fi
    block+=$'\n'"  current name: \"${pname:-none}\""
    ctx[$wid]+=$'\n'"$block"$'\n'
    fp[$wid]+="$pane|$path|$g_branch|$fg;"
    unlocked[$wid]+="$n:$pane "
  done <<<"$out"

  jobs >/dev/null
  running=$(jobs -rp | wc -l)
  for wid in "${!fp[@]}"; do
    hash=$(cksum <<<"${fp[$wid]}")
    hash=${hash%% *}
    if [ "$hash" = "${named[$wid]}" ]; then
      unset 'pending[$wid]'
      continue
    fi
    [ -n "${wlocked[$wid]:-}" ] && [ -z "${unlocked[$wid]:-}" ] && continue
    if [ "${pending[$wid]:-}" != "$hash" ]; then
      pending[$wid]=$hash
      continue
    fi
    [ -n "${job_of[$wid]:-}" ] && kill -0 "${job_of[$wid]}" 2>/dev/null && continue
    ((EPOCHSECONDS - ${last_try[$wid]:-0} < MIN_INTERVAL)) && continue
    ((running >= MAX_JOBS)) && break
    last_try[$wid]=$EPOCHSECONDS
    name_window "$wid" "$hash" "${hdr[$wid]}" "${ctx[$wid]}" "${unlocked[$wid]:-}" &
    job_of[$wid]=$!
    running=$((running + 1))
  done

  for wid in "${!last_try[@]}"; do
    [ -n "${fp[$wid]+x}" ] || unset 'last_try[$wid]' 'job_of[$wid]' 'pending[$wid]'
  done
  unset fp named hdr ctx unlocked count wlocked

  sleep "$TICK"
done
