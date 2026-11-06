# tmux-agents resume: map agent panes (omp, opencode, claude) to their sessions and
# resume them after tmux-resurrect restores. Sourced by tmux-agents.sh (shares
# opt, field, agent_kind, runtime_dir, TAB). Everything here is off when
# @tmux-agents-resume is off.
#
# resume.tsv: `session window pane agent ref state` per agent pane; ref is the
# session JSONL for omp and the session ID for opencode and claude. Rows without the
# agent column (written before opencode support) are omp; rows without a
# state (written before state tracking) are live. States:
#   live      the agent was running at the last save
#   pending   restore attempted, session not successfully resolved since
#   gone:T    the agent stopped at epoch T (dropped after resume_grace)
# A row only leaves the map when its pane closes, another agent takes the
# pane, its session no longer exists, or its agent stayed gone for the grace
# period. A pane's title never decides it: shells retitle the pane as soon
# as an agent dies, which happens at every shutdown and failed resume.

omp_dir="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
# opencode resolves a relative OPENCODE_DB against its data dir.
oc_db="${OPENCODE_DB:-opencode.db}"
[[ $oc_db == /* ]] || oc_db="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/$oc_db"
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-agents"
resume_file="$state_dir/resume.tsv"
# Per-row outcome of the last restore (sent / skipped and why / gave up).
restore_log="$state_dir/restore.log"
# Seconds a stopped agent keeps its row before a later save drops it.
# Covers agents dying just before tmux at shutdown. Quitting then restarting
# before that save can resume the agent again.
resume_grace=60

resume_on() { [ "$(opt @tmux-agents-resume on)" = on ]; }

# Called by the plugin loader: add our commands to resurrect's hook options
# (keeping anything already there), or take them out when resume is off, so
# toggling + re-sourcing tmux.conf applies either way.
cmd_resume_init() {
	local self name cmd existing kept part
	self=$(command -v "$0" || printf '%s' "$0")
	for name in @resurrect-hook-pre-restore-all @resurrect-hook-post-save-all @resurrect-hook-post-restore-all; do
		case "$name" in *pre-restore*) cmd="$self restore-begin" ;; *save*) cmd="$self save" ;; *) cmd="$self restore" ;; esac
		existing=$(tmux show-option -gqv "$name")
		# Drop our previous entries (any store path), keep the user's.
		kept=""
		while IFS= read -r part; do
			part=${part# }
			case "$part" in '' | *tmux-agents" save" | *tmux-agents" restore" | *tmux-agents" restore-begin") continue ;; esac
			kept+="${kept:+; }$part"
		done <<<"${existing//; /$'\n'}"
		if resume_on; then kept+="${kept:+; }$cmd"; fi
		if [ -n "$kept" ]; then
			tmux set-option -g "$name" "$kept"
		else
			tmux set-option -gu "$name"
		fi
	done
}

# Resurrect changes pane titles and creates panes incrementally. Freeze saves
# before it starts; otherwise a tick can prune mappings before the post hook
# reads them. Serialize with saves already in flight.
cmd_restore_begin() {
	local rt
	rt=$(runtime_dir)
	mkdir -p "$state_dir"
	(
		flock -x 9
		: >"$rt/restoring"
	) 9>"$state_dir/resume.lock"
}

# Tick hook: resurrect only saves every few minutes, so re-save the map when
# the set of agent panes (or their session labels) changes. That keeps a
# kill-server or crash between resurrect saves resumable. $1 = signature.
# The signature is only recorded once every agent pane resolved its session:
# omp creates the JSONL lazily and opencode only shows a session's title once
# it has one, so a just-started agent is retried on later ticks instead of
# being dropped for good.
resume_track() {
	local sig=$1 rt
	resume_on || return 0
	rt=$(runtime_dir)
	[ "$sig" = "$(cat "$rt/agents.sig" 2>/dev/null)" ] && return 0
	{ cmd_save && printf '%s' "$sig" >"$rt/agents.sig"; } >/dev/null 2>&1 </dev/null 9>&- &
}

# Agent running under pane process $1 ($2 = pane title, used by opencode).
# Sets found_kind (omp|opencode|claude) and REPLY (the row's ref). Returns 1 if an
# agent runs but its session isn't known yet, 2 if no agent process runs in
# the pane (the pane title can be stale, e.g. restored by resurrect). Sandbox
# wrappers (nono) run the agent as their child. Needs `load_ps`.
declare -A ps_children=() ps_comm=()
found_kind=""
load_ps() {
	local pid ppid comm
	ps_children=()
	ps_comm=()
	while read -r pid ppid comm; do
		ps_children[$ppid]+="$pid "
		ps_comm[$pid]=$comm
	done < <(ps -e -o pid=,ppid=,comm=)
}
session_for_pane() {
	local queue=("$1") pid
	REPLY="" found_kind=""
	# Breadth-first: the shallowest agent process is the agent; deeper ones
	# are omp's workers or opencode's `serve` child (same comm).
	while [ "${#queue[@]}" -gt 0 ]; do
		pid=${queue[0]}
		queue=("${queue[@]:1}")
		case "${ps_comm[$pid]:-}" in
		omp) found_kind=omp ;;
		opencode | .opencode-wrapp) found_kind=opencode ;; # nix wrapper, cut to 15 chars
		claude | .claude-wrapped) found_kind=claude ;;
		*)
			# shellcheck disable=SC2206 # space separated pid list
			queue+=(${ps_children[$pid]:-})
			continue
			;;
		esac
		"${found_kind}_session" "$pid" "${2:-}"
		return
	done
	return 2
}

# omp: nono gives the agent its own pty, so omp's per-terminal breadcrumb
# keyed by the pane tty can point at an unrelated session. Prefer the session
# JSONL the agent process holds open, then the breadcrumb of the agent's own
# tty. Unknown until omp's first write.
crumb_file() {
	local name=${1#/dev/} lines
	REPLY=""
	[ -r "$omp_dir/terminal-sessions/${name//\//-}" ] || return 1
	mapfile -t -n 2 lines <"$omp_dir/terminal-sessions/${name//\//-}"
	REPLY=${lines[1]:-}
	case "$REPLY" in /* | '') ;; *) REPLY="${lines[0]}/$REPLY" ;; esac
	[ -e "$REPLY" ]
}
omp_session() {
	local agent=$1 fd link rel
	for fd in /proc/"$agent"/fd/*; do
		link=$(readlink "$fd" 2>/dev/null) || continue
		rel=${link#"$omp_dir/sessions/"}
		# sessions/<dir>/<session>.jsonl; deeper files are subagent logs.
		if [ "$rel" != "$link" ] && [[ $rel == */*.jsonl ]] && [[ $rel != */*/* ]]; then
			REPLY=$link
			return 0
		fi
	done
	link=$(readlink "/proc/$agent/fd/0" 2>/dev/null) && crumb_file "$link" && return 0
	return 1
}

# opencode keeps every session in one SQLite database, so there is no open
# per-session file. The command line names the session when started with
# -s/--session (as resumed panes are), unless the TUI has since switched to
# another session: that shows in the title (`OC | <title>`, cut to 37 chars +
# `…` (U+2026) beyond 40), which is checked against the ID when present. Otherwise
# the newest root session under the agent's cwd with that title wins. A bare
# `OpenCode` title (home screen, untitled session) is unresolvable.
oc_sql() {
	[ -r "$oc_db" ] || return 1
	sqlite3 -readonly -batch -noheader -cmd '.timeout 2000' "$oc_db" "$1" 2>/dev/null
}
sql_str() { REPLY="'${1//\'/\'\'}'"; }
# Returns 0 for an existing session, 1 for confirmed absence, 2 on query error.
opencode_exists() {
	local result
	sql_str "$1"
	result=$(oc_sql "SELECT 1 FROM session_v2 WHERE id = $REPLY") || return 2
	[ -n "$result" ]
}
opencode_session() {
	local pid=$1 title=${2#OC | } id="" arg prev="" match="" cwd
	local -a argv=()
	[ -r "/proc/$pid/cmdline" ] && mapfile -d '' -t argv <"/proc/$pid/cmdline"
	for arg in "${argv[@]:1}"; do
		case "$prev" in -s | --session) id=$arg ;; esac
		case "$arg" in --session=*) id=${arg#--session=} ;; esac
		prev=$arg
	done
	if [ "$title" != "${2:-}" ] && [ -n "$title" ]; then
		sql_str "$title" && match="title = $REPLY"
		# JS slices 37 UTF-16 units; SQLite counts code points, so compare
		# against the prefix's own length (they differ for astral chars).
		if [[ $title == *… ]]; then
			sql_str "${title%…}" && match="($match OR (length(title) > length($REPLY) AND substr(title, 1, length($REPLY)) = $REPLY))"
		fi
	fi
	if [ -n "$id" ]; then
		REPLY=$id
		if [ -z "$match" ] || [ ! -r "$oc_db" ]; then return 0; fi
		sql_str "$id"
		[ -n "$(oc_sql "SELECT 1 FROM session_v2 WHERE id = $REPLY AND $match")" ] && REPLY=$id && return 0
	fi
	REPLY=""
	[ -n "$match" ] && cwd=$(readlink "/proc/$pid/cwd") || return 1
	sql_str "$cwd"
	# The session directory is the cwd or, failing that, an ancestor of it.
	REPLY=$(oc_sql "SELECT id FROM session_v2 WHERE parent_id IS NULL
		AND (directory = $REPLY OR substr($REPLY, 1, length(directory) + 1) = directory || '/')
		AND $match ORDER BY directory = $REPLY DESC, time_updated DESC LIMIT 1")
	[ -n "$REPLY" ]
}

# Claude Code writes $claude_dir/sessions/<pid>.json ({"pid":…,"sessionId":…})
# for each interactive process and keeps it current; transcripts live in
# $claude_dir/projects/<sanitized-cwd>/<sessionId>.jsonl.
claude_session() {
	local f="$claude_dir/sessions/$1.json" json re='"sessionId"[[:space:]]*:[[:space:]]*"([0-9a-fA-F-]+)"'
	REPLY=""
	[ -r "$f" ] || return 1
	json=$(<"$f")
	[[ $json =~ $re ]] || return 1
	REPLY=${BASH_REMATCH[1]}
}
# 0 if the session's transcript exists, 1 if not.
claude_exists() {
	local f
	for f in "$claude_dir"/projects/*/"$1.jsonl"; do
		[ -e "$f" ] && return 0
	done
	return 1
}

# Splits resume.tsv line $1 into row_s row_w row_p row_agent row_ref
# row_state, upgrading the older 4- and 5-column formats.
split_row() {
	IFS=$TAB read -r row_s row_w row_p row_agent row_ref row_state <<<"$1"
	[ -n "$row_ref" ] || { row_ref=$row_agent && row_agent=omp; }
	[ -n "$row_state" ] || row_state=live
}

# Writes resume.tsv. Run by the tmux-resurrect post-save hook, and by the tick
# whenever the set of agent panes changes so a kill-server between resurrect
# saves still has a current map. Per existing pane, by what actually runs in
# it (not its title):
#   agent with known session      row = that session, live
#   agent, session not known yet  old row kept (if the same agent kind);
#                                 pending stays pending; tick retries
#   no agent                      pending stays; live becomes gone:now; gone
#                                 rows older than resume_grace are dropped
# Rows for closed panes are dropped. A failed or empty pane listing (server
# exiting) leaves the file untouched.
cmd_save() (
	mkdir -p "$state_dir"
	exec 9>"$state_dir/resume.lock"
	flock -x 9
	[ ! -e "$(runtime_dir)/restoring" ] || return 1
	local tmp="$resume_file.$$" panes line s wi pi ppid cmd title key row out="" rc=0 r now
	local -A prev=()
	panes=$(tmux list-panes -a -F "#{session_name}${TAB}#{window_index}${TAB}#{pane_index}${TAB}#{pane_pid}${TAB}$(field pane_current_command)${TAB}#{pane_title}") || return 1
	[ -n "$panes" ] || return 1
	if [ -r "$resume_file" ]; then
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			split_row "$line"
			prev["$row_s:$row_w.$row_p"]="$row_agent$TAB$row_ref$TAB$row_state"
		done <"$resume_file"
	fi
	printf -v now '%(%s)T' -1
	load_ps
	while IFS=$TAB read -r s wi pi ppid cmd title; do
		key="$s:$wi.$pi"
		row=${prev[$key]:-}
		agent_kind "$title" "$cmd"
		# Panes with neither an agent title nor a row: nothing to track.
		[ -n "$REPLY" ] || [ -n "$row" ] || continue
		session_for_pane "$ppid" "$title" && r=0 || r=$?
		case "$r" in
		0) row="$found_kind$TAB$REPLY${TAB}live" ;;
		1)
			rc=1
			if [ "${row%%"$TAB"*}" != "$found_kind" ]; then
				row=""
			elif [ "${row##*"$TAB"}" != pending ]; then
				row="${row%"$TAB"*}${TAB}live"
			fi
			;;
		*)
			case "${row##*"$TAB"}" in
			live) row="${row%"$TAB"*}${TAB}gone:$now" ;;
			gone:*) [ $((now - ${row##*"${TAB}gone:"})) -lt "$resume_grace" ] || row="" ;;
			esac
			;;
		esac
		[ -z "$row" ] || out+="$s$TAB$wi$TAB$pi$TAB$row"$'\n'
	done <<<"$panes"
	printf '%s' "$out" >"$tmp"
	mv -f "$tmp" "$resume_file"
	return $rc
)

# tmux-resurrect post-restore hook: resume agents in restored panes. Restored
# panes first replay their saved contents, so wait (in the background, up to
# ~15s) for each to reach a shell. Mode `auto` runs the resume command;
# `prompt` only types it so you can press Enter (or not). Rows whose session
# is gone are dropped: `opencode -s` with an unknown ID starts a new session.
# Rows sent a resume become pending, so a resume that never comes up keeps its
# row; running `tmux-agents restore` again retries it. Each row's outcome goes
# to restore.log.
cmd_restore() (
	local resume_omp resume_oc resume_cc mode target cmd i line rt ppid shell r out=""
	local -a rows=()
	rt=$(runtime_dir)
	mkdir -p "$state_dir"
	exec 9>"$state_dir/resume.lock"
	flock -x 9
	# Also serialize manual restores with saves and other restore workers.
	trap 'rm -f "$rt/restoring" "$resume_file.$$"' EXIT
	[ -r "$resume_file" ] || return 0
	: >"$rt/restoring"
	resume_omp=$(opt @tmux-agents-resume-command 'omp --resume=')
	resume_oc=$(opt @tmux-agents-resume-command-opencode 'opencode -s ')
	resume_cc=$(opt @tmux-agents-resume-command-claude 'claude --resume ')
	mode=$(opt @tmux-agents-resume-mode auto)
	shell=$(tmux show-option -gqv default-shell)
	shell=${shell##*/}
	mapfile -t rows <"$resume_file"
	printf '%(%F %T)T restore: %d rows, shell %s\n' -1 "${#rows[@]}" "$shell" >"$restore_log"
	load_ps
	for line in "${rows[@]}"; do
		[ -n "$line" ] || continue
		split_row "$line"
		target="=$row_s:$row_w.$row_p"
		case "$row_agent" in
		omp) [ -e "$row_ref" ] && r=0 || r=1 ;;
		opencode) opencode_exists "$row_ref" && r=0 || r=$? ;;
		claude) claude_exists "$row_ref" && r=0 || r=1 ;;
		*) r=1 ;;
		esac
		if [ "$r" = 2 ]; then
			printf '%(%T)T %s skipped: %s session %s lookup failed; retained pending\n' -1 "$target" "$row_agent" "$row_ref" >>"$restore_log"
			out+="$row_s$TAB$row_w$TAB$row_p$TAB$row_agent$TAB$row_ref${TAB}pending"$'\n'
			continue
		fi
		if [ "$r" != 0 ]; then
			printf '%(%T)T %s dropped: %s session %s no longer exists\n' -1 "$target" "$row_agent" "$row_ref" >>"$restore_log"
			continue
		fi
		# A manual restore can leave existing agent panes untouched.
		if ! ppid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null); then
			printf '%(%T)T %s skipped: no such pane\n' -1 "$target" >>"$restore_log"
			out+="$line"$'\n'
			continue
		fi
		session_for_pane "$ppid" && r=0 || r=$?
		if [ "$r" != 2 ]; then # unresolved agents are still running agents
			printf '%(%T)T %s skipped: %s already running\n' -1 "$target" "$found_kind" >>"$restore_log"
			out+="$line"$'\n'
			continue
		fi
		out+="$row_s$TAB$row_w$TAB$row_p$TAB$row_agent$TAB$row_ref${TAB}pending"$'\n'
		case "$row_agent" in
		omp) line=$resume_omp ;;
		claude) line=$resume_cc ;;
		*) line=$resume_oc ;;
		esac
		line+=$(printf '%q' "$row_ref")
		(
			for ((i = 0; i < 30; i++)); do
				if ! cmd=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null); then
					printf '%(%T)T %s gave up: pane closed\n' -1 "$target" >>"$restore_log"
					exit 0
				fi
				case "$cmd" in
				"$shell")
					sleep 0.5 # let the prompt draw so the keys land on it
					if ! tmux send-keys -t "$target" -l "$line" ||
						{ [ "$mode" = auto ] && ! tmux send-keys -t "$target" Enter; }; then
						printf '%(%T)T %s gave up: send-keys failed\n' -1 "$target" >>"$restore_log"
					else
						printf '%(%T)T %s sent (%s) after %d polls: %s\n' -1 "$target" "$mode" "$i" "$line" >>"$restore_log"
					fi
					exit 0
					;;
				esac
				sleep 0.5
			done
			printf '%(%T)T %s gave up: pane still runs %s, not %s\n' -1 "$target" "$cmd" "$shell" >>"$restore_log"
		) </dev/null >/dev/null 2>&1 &
	done
	printf '%s' "$out" >"$resume_file.$$"
	mv -f "$resume_file.$$" "$resume_file"
	wait
)
