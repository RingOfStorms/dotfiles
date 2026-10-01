# tmux-agents resume: map agent panes to their session files and resume them
# after tmux-resurrect restores. Sourced by tmux-agents.sh (shares opt,
# classify, runtime_dir, TAB). Everything here is off when
# @tmux-agents-resume is off.

agent_dir="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
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
# The signature is only recorded once every agent pane resolved to an existing
# session file: omp creates the JSONL lazily, so a just-started agent is
# retried on later ticks instead of being dropped for good.
resume_track() {
	local sig=$1 rt
	resume_on || return 0
	rt=$(runtime_dir)
	[ "$sig" = "$(cat "$rt/agents.sig" 2>/dev/null)" ] && return 0
	{ cmd_save && printf '%s' "$sig" >"$rt/agents.sig"; } >/dev/null 2>&1 </dev/null &
}

# Session file of the agent running under pane process $1. Sandbox wrappers
# (nono) give the agent its own pty, so omp's per-terminal breadcrumb keyed by
# the pane tty can point at an unrelated session. Prefer the session JSONL the
# agent process holds open, then the breadcrumb of the agent's own tty.
# Returns 1 if an agent runs but its session file isn't known yet (omp only
# creates it on the first write), 2 if no agent process runs in the pane (the
# pane title can be stale, e.g. restored by resurrect). Needs `load_ps`.
declare -A ps_children=() ps_comm=()
load_ps() {
	local pid ppid comm
	ps_children=()
	ps_comm=()
	while read -r pid ppid comm; do
		ps_children[$ppid]+="$pid "
		ps_comm[$pid]=$comm
	done < <(ps -e -o pid=,ppid=,comm=)
}
crumb_file() {
	local name=${1#/dev/} lines
	REPLY=""
	[ -r "$agent_dir/terminal-sessions/${name//\//-}" ] || return 1
	mapfile -t -n 2 lines <"$agent_dir/terminal-sessions/${name//\//-}"
	REPLY=${lines[1]:-}
	case "$REPLY" in /* | '') ;; *) REPLY="${lines[0]}/$REPLY" ;; esac
	[ -e "$REPLY" ]
}
session_for_pane() {
	local queue=("$1") pid agent="" fd link rel
	REPLY=""
	# Breadth-first: the shallowest omp is the agent; deeper ones are workers.
	while [ "${#queue[@]}" -gt 0 ]; do
		pid=${queue[0]}
		queue=("${queue[@]:1}")
		if [ "${ps_comm[$pid]:-}" = omp ]; then
			agent=$pid
			break
		fi
		# shellcheck disable=SC2206 # space separated pid list
		queue+=(${ps_children[$pid]:-})
	done
	[ -n "$agent" ] || return 2
	for fd in /proc/"$agent"/fd/*; do
		link=$(readlink "$fd" 2>/dev/null) || continue
		rel=${link#"$agent_dir/sessions/"}
		# sessions/<dir>/<session>.jsonl; deeper files are subagent logs.
		if [ "$rel" != "$link" ] && [[ $rel == */*.jsonl ]] && [[ $rel != */*/* ]]; then
			REPLY=$link
			return 0
		fi
	done
	link=$(readlink "/proc/$agent/fd/0" 2>/dev/null) && crumb_file "$link" && return 0
	return 1
}

# Writes resume.tsv: one row per agent pane. Run by the tmux-resurrect
# post-save hook, and by the tick whenever the set of agent panes changes so a
# kill-server between resurrect saves still has a current map.
# A pane without a resolvable session keeps its previous row: either resurrect
# just restored the old `π` title onto a fresh shell (a save racing the restore
# must not wipe the map), or a starting agent hasn't written its session yet.
# Rows for panes that no longer exist are dropped. Returns 1 while a running
# agent's session is unresolved, so the tick retries.
cmd_save() (
	mkdir -p "$state_dir"
	exec 9>"$state_dir/resume.lock"
	flock -x 9
	[ ! -e "$(runtime_dir)/restoring" ] || return 1
	local tmp="$resume_file.$$" s wi pi ppid title key rc=0 r
	local -A prev=()
	if [ -r "$resume_file" ]; then
		while IFS=$TAB read -r s wi pi title; do
			prev["$s:$wi.$pi"]=$title
		done <"$resume_file"
	fi
	load_ps
	: >"$tmp"
	while IFS=$TAB read -r s wi pi ppid title; do
		classify "$title"
		[ "$REPLY" = none ] && continue
		key="$s:$wi.$pi"
		session_for_pane "$ppid" && r=0 || r=$?
		[ "$r" = 1 ] && rc=1
		[ "$r" = 0 ] || REPLY=${prev[$key]:-}
		[ -n "$REPLY" ] && printf '%s\t%s\t%s\t%s\n' "$s" "$wi" "$pi" "$REPLY" >>"$tmp"
	done < <(tmux list-panes -a -F "#{session_name}${TAB}#{window_index}${TAB}#{pane_index}${TAB}#{pane_pid}${TAB}#{pane_title}")
	mv -f "$tmp" "$resume_file"
	return $rc
)

# tmux-resurrect post-restore hook: resume agents in restored panes. Restored
# panes first replay their saved contents, so wait (in the background, up to
# ~15s) for each to reach a shell. Mode `auto` runs the resume command;
# `prompt` only types it so you can press Enter (or not).
cmd_restore() {
	local resume mode s wi pi file target cmd i line rt ppid shell r
	rt=$(runtime_dir)
	if [ ! -r "$resume_file" ]; then rm -f "$rt/restoring"; return 0; fi
	resume=$(opt @tmux-agents-resume-command 'omp --resume=')
	mode=$(opt @tmux-agents-resume-mode auto)
	shell=$(tmux show-option -gqv default-shell)
	shell=${shell##*/}
	load_ps
	while IFS=$TAB read -r s wi pi file; do
		[ -e "$file" ] || continue
		target="=$s:$wi.$pi"
		line="$resume$(printf '%q' "$file")"
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
