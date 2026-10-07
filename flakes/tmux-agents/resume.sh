# tmux-agents resume: map agent panes (omp, opencode) to their sessions and
# resume them after tmux-resurrect restores. Sourced by tmux-agents.sh (shares
# opt, field, agent_kind, runtime_dir, TAB). Everything here is off when
# @tmux-agents-resume is off.
#
# resume.tsv: `session window pane agent ref` per agent pane; ref is the
# session JSONL for omp and the session ID for opencode. Rows without the
# agent column (written before opencode support) are omp.

omp_dir="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
# opencode resolves a relative OPENCODE_DB against its data dir.
oc_db="${OPENCODE_DB:-opencode.db}"
[[ $oc_db == /* ]] || oc_db="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/$oc_db"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-agents"
resume_file="$state_dir/resume.tsv"

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
	{ cmd_save && printf '%s' "$sig" >"$rt/agents.sig"; } >/dev/null 2>&1 </dev/null &
}

# Agent running under pane process $1 ($2 = pane title, used by opencode).
# Sets found_kind (omp|opencode) and REPLY (the row's ref). Returns 1 if an
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
opencode_exists() {
	sql_str "$1"
	[ -n "$(oc_sql "SELECT 1 FROM session_v2 WHERE id = $REPLY")" ]
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

# Writes resume.tsv: one row per agent pane. Run by the tmux-resurrect
# post-save hook, and by the tick whenever the set of agent panes changes so a
# kill-server between resurrect saves still has a current map.
# A pane without a resolvable session keeps its previous row: either resurrect
# just restored the old agent title onto a fresh shell (a save racing the
# restore must not wipe the map), or a starting agent hasn't got a session
# yet. Rows for panes that no longer exist are dropped. Returns 1 while a
# running agent's session is unresolved, so the tick retries.
cmd_save() (
	mkdir -p "$state_dir"
	exec 9>"$state_dir/resume.lock"
	flock -x 9
	[ ! -e "$(runtime_dir)/restoring" ] || return 1
	local tmp="$resume_file.$$" s wi pi ppid cmd title key rc=0 r agent ref
	local -A prev=()
	if [ -r "$resume_file" ]; then
		while IFS=$TAB read -r s wi pi agent ref; do
			[ -n "$ref" ] || { ref=$agent && agent=omp; }
			prev["$s:$wi.$pi"]="$agent$TAB$ref"
		done <"$resume_file"
	fi
	load_ps
	: >"$tmp"
	while IFS=$TAB read -r s wi pi ppid cmd title; do
		agent_kind "$title" "$cmd"
		# An opencode title on a shell is stale (resurrect restores titles):
		# like omp's `π`, it keeps the pane's row.
		[ -n "$REPLY" ] || agent_kind "$title" opencode
		[ -n "$REPLY" ] || continue
		key="$s:$wi.$pi"
		session_for_pane "$ppid" "$title" && r=0 || r=$?
		if [ "$r" = 0 ]; then
			REPLY="$found_kind$TAB$REPLY"
		else
			[ "$r" = 1 ] && rc=1
			REPLY=${prev[$key]:-}
			# The pane's old row belongs to a different agent than the one now running.
			if [ "$r" = 1 ] && [ "${REPLY%%"$TAB"*}" != "$found_kind" ]; then REPLY=""; fi
		fi
		[ -n "$REPLY" ] && printf '%s\t%s\t%s\t%s\n' "$s" "$wi" "$pi" "$REPLY" >>"$tmp"
	done < <(tmux list-panes -a -F "#{session_name}${TAB}#{window_index}${TAB}#{pane_index}${TAB}#{pane_pid}${TAB}$(field pane_current_command)${TAB}#{pane_title}")
	mv -f "$tmp" "$resume_file"
	return $rc
)

# tmux-resurrect post-restore hook: resume agents in restored panes. Restored
# panes first replay their saved contents, so wait (in the background, up to
# ~15s) for each to reach a shell. Mode `auto` runs the resume command;
# `prompt` only types it so you can press Enter (or not). Rows whose session
# is gone are skipped: `opencode -s` with an unknown ID starts a new session.
cmd_restore() {
	local resume_omp resume_oc mode s wi pi agent ref target cmd i line rt ppid shell r
	rt=$(runtime_dir)
	if [ ! -r "$resume_file" ]; then rm -f "$rt/restoring"; return 0; fi
	resume_omp=$(opt @tmux-agents-resume-command 'omp --resume=')
	resume_oc=$(opt @tmux-agents-resume-command-opencode 'opencode -s ')
	mode=$(opt @tmux-agents-resume-mode auto)
	shell=$(tmux show-option -gqv default-shell)
	shell=${shell##*/}
	load_ps
	while IFS=$TAB read -r s wi pi agent ref; do
		[ -n "$ref" ] || { ref=$agent && agent=omp; }
		case "$agent" in
		omp) [ -e "$ref" ] || continue ;;
		opencode) opencode_exists "$ref" || continue ;;
		*) continue ;;
		esac
		if [ "$agent" = omp ]; then line=$resume_omp; else line=$resume_oc; fi
		line+=$(printf '%q' "$ref")
		target="=$s:$wi.$pi"
		# A manual restore can leave existing agent panes untouched.
		ppid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || continue
		session_for_pane "$ppid" && r=0 || r=$?
		[ "$r" = 2 ] || continue # unresolved agents are still running agents
		(
			for ((i = 0; i < 30; i++)); do
				cmd=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null) || exit 0
				case "$cmd" in
				"$shell")
					sleep 0.5 # let the prompt draw so the keys land on it
					tmux send-keys -t "$target" -l "$line"
					if [ "$mode" = auto ]; then tmux send-keys -t "$target" Enter; fi
					exit 0
					;;
				esac
				sleep 0.5
			done
		) </dev/null >/dev/null 2>&1 &
	done <"$resume_file"
	wait
	rm -f "$rt/restoring"
}
