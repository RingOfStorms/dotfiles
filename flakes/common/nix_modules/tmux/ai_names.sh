# tmux-ai-names: label tmux sessions and name windows with the fast LLM tier.
#
# One background instance per tmux server, started from tmux.conf. Every TICK
# seconds each session is fingerprinted from its panes' cwd, git branch,
# foreground program and agent title. When a fingerprint changes and stays
# stable for one more tick, the session's context goes to the fast model, which
# returns a short session label (@session_ai_name, shown in the tmux-agents
# navigator beside the real session name) and 1-2 word window names
# (@window_ai_name, shown through automatic-rename-format). Session names
# themselves are never changed, so attach targets and resurrect are unaffected.
#
# Privacy: only metadata leaves the machine, never screen contents or full
# command lines. Per pane: cwd, git repo/branch, the program name plus at most
# one lowercase subcommand word (`cargo test`, `nix develop`), the host for
# ssh, and agent titles (omp/opencode session labels).
#
# Never blocking: tmux only ever reads user options, so if the model is slow or
# h001 is down tmux keeps its normal names and nothing waits. Requests are
# capped at LLM_MAX_TIME, and repeated failures back off.
#
# Humans win: windows renamed manually (automatic-rename off, `prefix ,`) are
# never renamed.
#   tmux set -g @ai_names off|on             toggle (`prefix A`); off clears AI names
#   tmux set -g @ai_names_model <model>      override the model live
#   tmux set -g @ai_names_reasoning <effort>
# Log: $XDG_RUNTIME_DIR/tmux-ai-names_<socket>.log

readonly TICK=3 MIN_INTERVAL=15 MAX_JOBS=4
readonly S=$'\x1f'
readonly FMT="$S#{session_id}$S#{session_name}$S#{@session_ai_name}$S#{@session_ai_fp}$S#{window_id}$S#{window_index}$S#{automatic-rename}$S#{window_name}$S#{@window_ai_name}$S#{pane_pid}$S#{pane_current_path}$S#{pane_current_command}$S#{@agent_state}$S#{pane_dead}$S#{pane_title}"
export LLM_MAX_TIME=30

readonly SYSTEM_PROMPT='You label tmux sessions and windows so a developer can jump to a piece of work by typing a few letters into a fuzzy finder.
Return only a JSON object: {"session": "<label>", "windows": {"<window index>": "<name>"}}.
Session label: 1-2 words, max 20 characters, lowercase except ticket ids (e.g. ABC-123). Name what makes this session distinct: a ticket id or topic from the git branch, the feature an agent is working on, or the remote host for ssh. Prefer something more specific than the session or project name; use the project name only when nothing more specific exists. It must differ from the other sessions labels.
Window names: 1 word, 2 at most, max 16 characters, lowercase except ticket ids. Say what the window is for (e.g. server, tests, editor, logs, agent topic, or a host) so windows in the session are distinguishable.
Never use generic words like shell, terminal, zsh, home, session, window.
Keep a current name when it is still accurate. Omit locked windows.'

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

# fg_desc <pane-pid> <pane-current-command>: sets fg to a secret-free summary
# of the pane's foreground program, or "" when the pane's shell is idle.
# Arguments are dropped except one plain lowercase subcommand word and the ssh
# destination host: tokens, passwords and paths rarely match that shape.
fg_desc() {
  fg=
  local stat rest tpgid prog a host skip=
  read -r stat <"/proc/$1/stat" 2>/dev/null || return 0
  rest=${stat##*) }
  read -r _ _ _ _ _ tpgid _ <<<"$rest"
  [ "${tpgid:-0}" -gt 0 ] || return 0
  if [ "$tpgid" = "$1" ]; then
    case $2 in sh | bash | zsh | fish | nu) return 0 ;; esac
  fi
  local -a argv=()
  mapfile -d '' -t argv <"/proc/$tpgid/cmdline" 2>/dev/null
  prog=${argv[0]:-$2}
  prog=${prog##*/}
  prog=${prog#.}
  prog=${prog%-wrapped}
  [[ $prog =~ ^[A-Za-z0-9._+-]{1,32}$ ]] || prog=$2
  fg=$prog
  case $prog in
    ssh)
      for a in "${argv[@]:1}"; do
        if [ -n "$skip" ]; then
          skip=
          continue
        fi
        case $a in
          -[BbcDEeFIiJLlmOopQRSWw]) skip=1 ;;
          -*) ;;
          *)
            host=${a#ssh://}
            host=${host##*@}
            host=${host%%[:/]*}
            [[ $host =~ ^[A-Za-z0-9.-]{1,64}$ ]] && fg+=" $host"
            break
            ;;
        esac
      done
      ;;
    *)
      a=${argv[1]:-}
      [[ $a =~ ^[a-z][a-z-]{1,15}$ ]] && fg+=" $a"
      ;;
  esac
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

# Sets agent to the agent session label of a pane tmux-agents marked as an
# agent (@agent_state set): omp `π <glyph> label`, opencode `OC | label`.
agent_desc() {
  agent=
  [ -n "$1" ] || return 0
  case $2 in
    'π'*)
      agent=${2#π}
      agent=${agent# }
      agent=${agent#?}
      agent="omp: ${agent# }"
      ;;
    'OC | '*) agent="opencode: ${2#'OC | '}" ;;
    *) agent=agent ;;
  esac
  agent=${agent//[$'\n\t\x1f"']/ }
  agent=${agent:0:80}
}

# name_session <session-id> <fingerprint-hash> <prompt> <"index:@wid ...">
name_session() {
  local sid=$1 hash=$2 prompt=$3 entry reply parsed key name
  local -A wid_of=()
  for entry in $4; do
    wid_of[${entry%%:*}]=${entry#*:}
  done

  # Model: tmux option @ai_names_model / @ai_names_reasoning, else the module
  # defaults baked in at build time (the server environment goes stale).
  local MODEL_FAST MODEL_FAST_REASONING
  MODEL_FAST=$(tmux show -gqv @ai_names_model)
  MODEL_FAST=${MODEL_FAST:-$AI_NAMES_MODEL}
  MODEL_FAST_REASONING=$(tmux show -gqv @ai_names_reasoning)
  MODEL_FAST_REASONING=${MODEL_FAST_REASONING:-$AI_NAMES_REASONING}

  if ! reply=$(llm_chat fast "$SYSTEM_PROMPT" "$prompt"); then
    # Endpoint down/slow: leave the fingerprint unrecorded so the session is
    # renamed once it is back, and record the failure for the global backoff.
    local fails=0
    [ -r "$fail_file" ] && read -r _ fails <"$fail_file"
    printf '%s %s\n' "$EPOCHSECONDS" "$((fails + 1))" >"$fail_file"
    return 1
  fi
  rm -f "$fail_file"
  parsed=$(printf '%s' "$reply" | sed '/^[[:space:]]*```/d' | jq -r '
    def clean(n): tostring | gsub("[^A-Za-z0-9 ._/-]"; "") | [splits(" +")]
      | map(select(length > 0)) | .[:2] | join(" ") | .[:n];
    ("s\t" + (.session // "" | clean(20))),
    ((.windows // {}) | to_entries[] | "\(.key | gsub("[^0-9]"; ""))\t\(.value | clean(16))")
  ' 2>/dev/null)
  if [ -z "$parsed" ]; then
    printf '%s: unusable reply for %s: %s\n' "$(date -Is)" "$sid" "$reply"
  fi

  # Names are reduced to [A-Za-z0-9 ._/-] above, so they are safe inside tmux
  # double quotes. The window lock and on/off checks run inside tmux,
  # atomically with the set, so a manual rename is never overwritten. Setting
  # automatic-rename forces tmux to re-evaluate automatic-rename-format.
  while IFS=$'\t' read -r key name; do
    [ -n "$name" ] || continue
    if [ "$key" = s ]; then
      tmux set -t "$sid" @session_ai_name "$name"
    elif [ -n "${wid_of[$key]:-}" ]; then
      local wid=${wid_of[$key]}
      tmux if -F -t "$wid" '#{&&:#{automatic-rename},#{!=:#{@ai_names},off}}' \
        "set -w -t $wid @window_ai_name \"$name\" ; set -w -t $wid automatic-rename on"
    fi
  done <<<"$parsed"
  # Recorded even for an unusable reply so a stable session is not re-asked.
  tmux set -t "$sid" @session_ai_fp "$hash"
}

# Drop every AI name so tmux shows its normal names again. Manual window names
# (automatic-rename off) are kept.
clear_ai_names() {
  local id auto
  tmux list-sessions -F '#{session_id}' | while read -r id; do
    tmux set -u -t "$id" @session_ai_name \; set -u -t "$id" @session_ai_fp
  done
  tmux list-windows -a -F "#{window_id}$S#{automatic-rename}" | while IFS=$S read -r id auto; do
    tmux set -wu -t "$id" @window_ai_name
    # Re-setting automatic-rename makes tmux re-evaluate the name right away.
    [ "$auto" = 1 ] && tmux set -w -t "$id" automatic-rename on
  done
}

# Pane names are no longer AI-set; drop ones left by earlier versions. Manual
# names (`prefix .`, @pane_name_manual) stay.
tmux list-panes -a -F "#{pane_id}$S#{@pane_name_manual}$S#{@pane_name}" | while IFS=$S read -r id manual pname; do
  [ -z "$manual" ] && [ -n "$pname" ] && tmux set -pu -t "$id" @pane_name
done

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

  declare -A fp=() named=() ctx=() wins=() labels=() seen_win=()
  while IFS=$S read -r _ sid session sai sfp wid widx wauto wname wai panepid path cmd astate dead title; do
    [ "$dead" = 1 ] && continue
    if [ -z "${fp[$sid]+x}" ]; then
      named[$sid]=$sfp
      ctx[$sid]="Session \"$session\" (current label \"${sai:-none}\")"
      [ -n "$sai" ] && labels[$sid]="$session = \"$sai\""
    fi
    if [ -z "${seen_win[$wid]+x}" ]; then
      seen_win[$wid]=1
      if [ "$wauto" = 1 ]; then
        ctx[$sid]+=$'\n'"Window $widx (current name \"${wai:-none}\"):"
        wins[$sid]+="$widx:$wid "
        fp[$sid]+="w$widx;"
      else
        ctx[$sid]+=$'\n'"Window $widx (locked by user as \"$wname\"):"
        fp[$sid]+="w$widx|locked;"
      fi
    fi

    fg_desc "$panepid" "$cmd"
    git_info "$path"
    agent_desc "$astate" "$title"
    line="  Pane: cwd ${path/#$HOME/\~}"
    [ -n "$g_repo" ] && line+="; git $g_repo, branch ${g_branch:-unknown}"
    line+="; running ${fg:-idle shell}"
    [ -n "$agent" ] && line+="; agent $agent"
    ctx[$sid]+=$'\n'"$line"
    fp[$sid]+="$path|$g_branch|$fg|$agent;"
  done <<<"$out"

  jobs >/dev/null
  running=$(jobs -rp | wc -l)
  for sid in "${!fp[@]}"; do
    hash=$(cksum <<<"${fp[$sid]}")
    hash=${hash%% *}
    if [ "$hash" = "${named[$sid]}" ]; then
      unset 'pending[$sid]'
      continue
    fi
    if [ "${pending[$sid]:-}" != "$hash" ]; then
      pending[$sid]=$hash
      continue
    fi
    [ -n "${job_of[$sid]:-}" ] && kill -0 "${job_of[$sid]}" 2>/dev/null && continue
    ((EPOCHSECONDS - ${last_try[$sid]:-0} < MIN_INTERVAL)) && continue
    ((running >= MAX_JOBS)) && break
    others=
    for o in "${!labels[@]}"; do
      [ "$o" = "$sid" ] || others+=$'\n'"  ${labels[$o]}"
    done
    prompt=${ctx[$sid]}
    [ -n "$others" ] && prompt+=$'\n\n'"Other sessions' labels (yours must differ):$others"
    last_try[$sid]=$EPOCHSECONDS
    name_session "$sid" "$hash" "$prompt" "${wins[$sid]:-}" &
    job_of[$sid]=$!
    running=$((running + 1))
  done

  for sid in "${!last_try[@]}"; do
    [ -n "${fp[$sid]+x}" ] || unset 'last_try[$sid]' 'job_of[$sid]' 'pending[$sid]'
  done
  unset fp named ctx wins labels seen_win

  sleep "$TICK"
done
