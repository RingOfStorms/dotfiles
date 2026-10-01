# tmux-agents: agent-aware state, navigator, and resume for tmux.
# Subcommands: tick [quiet] | navigator | rows | preview <target> | kill <id> <rows> | save | restore
# Resume (save/restore) lives in resume.sh, sourced below.
#
# Detection is external only: coding agents announce their state through the
# terminal title (`#{pane_title}`). omp writes `π <spinner> label` while
# working, `π > label` when idle, and `π ! label` when blocked on the user.

TAB=$'\t'

opt() {
	local v
	v=$(tmux show-option -gqv "$1" 2>/dev/null || true)
	printf '%s' "${v:-$2}"
}

# `#{?x,#{x},-}`: keeps tab-separated rows aligned when a value is empty
# (tab is IFS whitespace, so `read` would collapse empty fields).
field() { printf '#{?%s,#{%s},-}' "$1" "$1"; }
undash() { [ "$1" = - ] && REPLY="" || REPLY=$1; }

# Sets REPLY to none|idle|working|input. One function per harness keeps room
# for title conventions other than omp's.
classify() {
	case "$1" in
	'π >'*) REPLY=idle ;;
	'π !'*) REPLY=input ;;
	'π' | 'π:'*) REPLY=idle ;; # title state disabled: presence only
	'π '?*) REPLY=working ;;
	*) REPLY=none ;;
	esac
}

# Rank used for roll-ups: input > working > done (idle, unseen) > idle > none.
rank() {
	case "$1" in
	input) REPLY=4 ;;
	working) REPLY=3 ;;
	idle) if [ -n "$2" ]; then REPLY=2; else REPLY=1; fi ;;
	*) REPLY=0 ;;
	esac
}

glyph() {
	case "$1" in
	4) printf '\033[1;31m!\033[0m' ;;
	3) printf '\033[33m⠿\033[0m' ;;
	2) printf '\033[32m●\033[0m' ;;
	1) printf '\033[2m○\033[0m' ;;
	*) printf ' ' ;;
	esac
}

runtime_dir() {
	local pid rest dir
	if [ -n "${TMUX:-}" ]; then
		rest=${TMUX#*,}
		pid=${rest%%,*}
	else
		pid=$(tmux display-message -p '#{pid}')
	fi
	dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-agents-$pid"
	mkdir -p "$dir"
	printf '%s' "$dir"
}

agent_label() {
	local l=${1#π}
	l=${l# }
	l=${l#?} # state glyph: spinner frame, '>', '!' or ':'
	REPLY=${l# }
}

# Events are queued during a tick and delivered once at the end, so several
# agents finishing together give one sound/message, not a burst.
declare -a ev_title=() ev_body=()
ev_input=0
notify() {
	ev_title+=("$1")
	ev_body+=("$2")
	if [ "$3" = input ]; then ev_input=1; fi
}

# Channels, each independently switchable (all gated by @tmux-agents-notify):
#   desktop  notify-send on the machine running tmux
#   message  tmux display-message on every attached client (works over ssh)
#   sound    off | local (play a file on the tmux host) | bell (BEL to each
#            attached client's terminal, so a phone/ssh client beeps/vibrates)
deliver() {
	local n=${#ev_title[@]} i msg sound file client tty vol
	[ "$n" -gt 0 ] || return 0
	[ "$(opt @tmux-agents-notify on)" = on ] || return 0
	if [ "$(opt @tmux-agents-notify-desktop on)" = on ] && command -v notify-send >/dev/null 2>&1; then
		for ((i = 0; i < n; i++)); do
			notify-send -a tmux-agents "${ev_title[i]}" "${ev_body[i]}" >/dev/null 2>&1 &
		done
	fi
	if [ "$(opt @tmux-agents-notify-message off)" = on ]; then
		msg="${ev_title[0]}: ${ev_body[0]}"
		if [ "$n" -gt 1 ]; then msg+=" (+$((n - 1)) more)"; fi
		while read -r client; do
			tmux display-message -c "$client" -d 4000 "$msg" >/dev/null 2>&1 || true
		done < <(tmux list-clients -F '#{client_name}' 2>/dev/null)
	fi
	sound=$(opt @tmux-agents-notify-sound local)
	case "$sound" in
	local)
		# Volume in percent (0-100); pw-play wants 0-1.0, paplay 0-65536.
		local def
		if [ "$ev_input" = 1 ]; then
			file=$(opt @tmux-agents-sound-input "") def=90
			vol=$(opt @tmux-agents-sound-input-volume $def)
		else
			file=$(opt @tmux-agents-sound-done "") def=15
			vol=$(opt @tmux-agents-sound-done-volume $def)
		fi
		[ -r "$file" ] || return 0
		[[ $vol =~ ^[0-9]+$ ]] || vol=$def
		if [ "$vol" -gt 100 ]; then vol=100; fi
		if command -v pw-play >/dev/null 2>&1; then
			pw-play --volume "$((vol / 100)).$(printf '%02d' $((vol % 100)))" "$file" >/dev/null 2>&1 &
		elif command -v paplay >/dev/null 2>&1; then
			paplay --volume "$((vol * 65536 / 100))" "$file" >/dev/null 2>&1 &
		fi
		;;
	bell)
		while read -r tty; do
			[ -w "$tty" ] && printf '\a' >"$tty" 2>/dev/null
		done < <(tmux list-clients -F '#{client_tty}' 2>/dev/null)
		;;
	esac
}

cmd_tick() {
	local quiet=${1:-} rt
	rt=$(runtime_dir)
	exec 9>"$rt/lock"
	if ! flock -n 9; then
		# Another client is ticking; show its last segment instead of blanking.
		if [ -z "$quiet" ]; then cat "$rt/segment" 2>/dev/null || true; fi
		return 0
	fi

	local fmt
	fmt="#{pane_id}${TAB}#{window_id}${TAB}#{session_name}${TAB}#{window_index}${TAB}$(field window_name)${TAB}#{pane_active}${TAB}#{window_active}${TAB}#{session_attached}${TAB}#{window_zoomed_flag}${TAB}$(field @agent_state)${TAB}$(field @agent_unseen)${TAB}$(field @agent_win)${TAB}#{pane_title}"

	local -A win_want=() win_have=()
	local -a cmds=()
	local n_work=0 n_input=0 n_done=0 agents_sig=""
	local pane win sess widx wname pact wact attached zoom st unseen walert title cur seen new_unseen
	while IFS=$TAB read -r pane win sess widx wname pact wact attached zoom st unseen walert title; do
		undash "$st" && st=$REPLY
		undash "$unseen" && unseen=$REPLY
		undash "$walert" && walert=$REPLY
		win_have[$win]=$walert
		[ -n "${win_want[$win]+x}" ] || win_want[$win]=""
		classify "$title" && cur=$REPLY

		seen=0
		if [ "$attached" != 0 ] && [ "$wact" = 1 ] && { [ "$zoom" = 0 ] || [ "$pact" = 1 ]; }; then
			seen=1
		fi

		new_unseen=$unseen
		agent_label "$title"
		if [ "$cur" != none ]; then agents_sig+="$pane=$REPLY;"; fi
		case "$cur" in
		none | working) new_unseen="" ;;
		idle)
			if [ "$st" = working ] && [ "$seen" = 0 ]; then
				new_unseen=1
				notify "Agent finished" "$sess:$widx $wname — $REPLY" "done"
			fi
			;;
		input)
			if [ "$st" != input ] && [ "$seen" = 0 ]; then
				new_unseen=1
				notify "Agent needs input" "$sess:$widx $wname — $REPLY" input
			fi
			;;
		esac
		if [ "$seen" = 1 ]; then new_unseen=""; fi

		if [ "$cur" = none ]; then
			if [ -n "$st" ]; then cmds+=(set-option -pu -t "$pane" @agent_state ';'); fi
		elif [ "$cur" != "$st" ]; then
			cmds+=(set-option -p -t "$pane" @agent_state "$cur" ';')
		fi
		if [ "$new_unseen" != "$unseen" ]; then
			if [ -n "$new_unseen" ]; then
				cmds+=(set-option -p -t "$pane" @agent_unseen 1 ';')
			else
				cmds+=(set-option -pu -t "$pane" @agent_unseen ';')
			fi
		fi

		if [ "$cur" = input ] && [ "$seen" = 0 ]; then
			win_want[$win]=input
		elif [ -n "$new_unseen" ] && [ "${win_want[$win]}" != input ]; then
			win_want[$win]="done"
		fi

		case "$cur" in
		working) n_work=$((n_work + 1)) ;;
		input) n_input=$((n_input + 1)) ;;
		idle) if [ -n "$new_unseen" ]; then n_done=$((n_done + 1)); fi ;;
		esac
	done < <(tmux list-panes -a -F "$fmt")

	for win in "${!win_want[@]}"; do
		[ "${win_want[$win]}" = "${win_have[$win]}" ] && continue
		if [ -n "${win_want[$win]}" ]; then
			cmds+=(set-option -w -t "$win" @agent_win "${win_want[$win]}" ';')
		else
			cmds+=(set-option -wu -t "$win" @agent_win ';')
		fi
	done
	if [ "${#cmds[@]}" -gt 0 ]; then
		unset 'cmds[-1]'
		tmux "${cmds[@]}" >/dev/null 2>&1 || true
	fi
	deliver
	resume_track "$agents_sig"

	local seg=""
	if [ "$n_input" -gt 0 ]; then seg+="#[fg=red,bold]! $n_input#[default] "; fi
	if [ "$n_work" -gt 0 ]; then seg+="#[fg=yellow]⠿ $n_work#[default] "; fi
	if [ "$n_done" -gt 0 ]; then seg+="#[fg=green]● $n_done#[default] "; fi
	if [ -n "$seg" ]; then seg="#[range=user|agents]${seg}#[norange]"; fi
	printf '%s' "$seg" >"$rt/segment.tmp" && mv -f "$rt/segment.tmp" "$rt/segment"
	if [ -z "$quiet" ]; then printf '%s' "$seg"; fi
}

# Git identity per path, cached for one invocation: "common<TAB>top<TAB>branch".
declare -A git_cache=()
git_info() {
	local p=$1 out
	if [ -z "${git_cache[$p]+x}" ]; then
		if out=$(git -C "$p" rev-parse --path-format=absolute --git-common-dir --show-toplevel --abbrev-ref HEAD 2>/dev/null); then
			git_cache[$p]=${out//$'\n'/$TAB}
		else
			git_cache[$p]=""
		fi
	fi
	REPLY=${git_cache[$p]}
}

tilde() { REPLY=${1/#"$HOME"/\~}; }

# Prints "target<TAB>display" rows, grouped repo -> worktree session -> windows.
# Grouping is recomputed from git each call, so a session that cd's into a
# worktree moves under its repo without any registration step.
CUR_POS=1
cmd_rows() {
	local current fmt
	current=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
	fmt="#{session_name}${TAB}#{window_index}${TAB}$(field window_name)${TAB}#{pane_id}${TAB}#{pane_active}${TAB}#{window_active}${TAB}$(field @agent_state)${TAB}$(field @agent_unseen)${TAB}$(field pane_current_path)"

	local -a sessions=()
	local -A s_rank=() s_pane=() s_path=() s_wins=() w_rank=() w_name=() w_pane=()
	local s wi wn pane pact wact st unseen path key
	while IFS=$TAB read -r s wi wn pane pact wact st unseen path; do
		undash "$st" && st=$REPLY
		undash "$unseen" && unseen=$REPLY
		undash "$path" && path=$REPLY
		key="$s:$wi"
		if [ -z "${s_rank[$s]+x}" ]; then
			sessions+=("$s")
			s_rank[$s]=0
			s_pane[$s]=$pane
			s_path[$s]=$path
			s_wins[$s]=""
		fi
		if [ -z "${w_rank[$key]+x}" ]; then
			s_wins[$s]+="$wi "
			w_rank[$key]=0
			w_name[$key]=$wn
			w_pane[$key]=$pane
		fi
		rank "$st" "$unseen"
		[ "$REPLY" -gt "${w_rank[$key]}" ] && w_rank[$key]=$REPLY
		[ "$REPLY" -gt "${s_rank[$s]}" ] && s_rank[$s]=$REPLY
		if [ "$pact" = 1 ]; then w_pane[$key]=$pane; fi
		if [ "$pact" = 1 ] && [ "$wact" = 1 ]; then
			s_pane[$s]=$pane
			s_path[$s]=$path
		fi
	done < <(tmux list-panes -a -F "$fmt")

	local -A s_repo=() s_branch=() s_main=() repo_name=() repo_root=()
	local common top branch main name sortable=""
	for s in "${sessions[@]}"; do
		git_info "${s_path[$s]}"
		if [ -n "$REPLY" ]; then
			IFS=$TAB read -r common top branch <<<"$REPLY"
			if [[ $common == */.git ]]; then main=${common%/.git}; else main=$common; fi
			name=${main##*/}
			name=${name%.git}
			[ "$branch" = HEAD ] && branch=detached
			s_repo[$s]=$common
			s_branch[$s]=$branch
			if [ "$top" = "$main" ]; then s_main[$s]=0; else s_main[$s]=1; fi
			repo_name[$common]=$name
			repo_root[$common]=$main
			sortable+="0${TAB}${name}${TAB}${common}${TAB}${s_main[$s]}${TAB}${branch}${TAB}${s}"$'\n'
		else
			s_repo[$s]="~other"
			sortable+="1${TAB}~${TAB}~other${TAB}0${TAB}-${TAB}${s}"$'\n'
		fi
	done

	local idx=0 prev="" _g _n _c _m _b repo row
	while IFS=$TAB read -r _g _n _c _m _b s; do
		[ -n "$s" ] || continue
		repo=${s_repo[$s]}
		if [ "$repo" != "$prev" ]; then
			prev=$repo
			if [ "$repo" = "~other" ]; then
				row=$'\033[1;35mother\033[0m'
			else
				tilde "${repo_root[$repo]}"
				row=$'\033[1;34m'"${repo_name[$repo]}"$'\033[0m  \033[2m'"$REPLY"$'\033[0m'
			fi
			printf 'h:%s\t%s\t%s\n' "$repo" "${s_pane[$s]}" "$row"
			idx=$((idx + 1))
		fi
		row="  $(glyph "${s_rank[$s]}") $s"
		if [ "$repo" = "~other" ]; then
			tilde "${s_path[$s]}"
			row+=$'  \033[2m'"$REPLY"$'\033[0m'
		else
			row+=$'  \033[36m['"${s_branch[$s]}"$']\033[0m'
			if [ "${s_main[$s]}" = 1 ]; then row+=$' \033[2mworktree\033[0m'; fi
		fi
		printf 's:%s\t%s\t%s\n' "$s" "${s_pane[$s]}" "$row"
		idx=$((idx + 1))
		[ "$s" = "$current" ] && CUR_POS=$idx
		# shellcheck disable=SC2086 # window index list is space separated
		set -- ${s_wins[$s]}
		if [ "$#" -gt 1 ]; then
			for wi in "$@"; do
				key="$s:$wi"
				printf 'w:%s\t%s\t      %s %s:%s\n' "$key" "${w_pane[$key]}" "$(glyph "${w_rank[$key]}")" "$wi" "${w_name[$key]}"
				idx=$((idx + 1))
			done
		fi
	done < <(printf '%s' "$sortable" | LC_ALL=C sort -t "$TAB" -k1,1 -k2,2 -k3,3 -k4,4n -k5,5 -k6,6)
}

cmd_preview() {
	local out
	out=$(tmux capture-pane -ep -t "$1" 2>/dev/null || true)
	printf '%s\n' "$out" | tail -n "${FZF_PREVIEW_LINES:-40}"
}

# Navigator ctrl-x: confirm, then kill the session or window under the cursor
# and rewrite the rows file the caller reloads. Repo headers are left alone.
cmd_kill() {
	local id=$1 rows=$2 kind target what ans
	kind=${id%%:*} target=${id#*:}
	case "$kind" in
	s) what="session '$target'" ;;
	w) what="window '$target'" ;;
	*) return 0 ;;
	esac
	printf 'Kill %s? [y/N] ' "$what" >/dev/tty
	read -r -n 1 ans </dev/tty || ans=""
	[[ $ans == [yY] ]] || return 0
	if [ "$kind" = s ]; then
		# Killing the session this client shows would detach it
		# (detach-on-destroy); move to another session first.
		if [ "$target" = "$(tmux display-message -p '#{session_name}')" ]; then
			tmux switch-client -l 2>/dev/null || tmux switch-client -n 2>/dev/null || true
		fi
		tmux kill-session -t "=$target"
	else
		tmux kill-window -t "=$target"
	fi
	cmd_rows >"$rows.tmp" && mv -f "$rows.tmp" "$rows"
}

# Live view: fzf listens on a socket; a background loop rebuilds the rows and
# pushes a reload only when they changed, so typing and the cursor are left
# alone. --track with --id-nth keeps the cursor on the same row across reloads.
cmd_navigator() {
	local rt sock rows sel self loop interval next
	self=$(command -v "$0" || printf '%s' "$0")
	rt=$(runtime_dir)
	sock="$rt/nav-$$.sock"
	rows="$rt/nav-$$.rows"
	interval=$(opt @tmux-agents-navigator-interval 1)
	cmd_rows >"$rows"
	(
		while sleep "$interval"; do
			[ -S "$sock" ] || continue
			git_cache=()
			next=$(cmd_rows) || continue
			if [ "$next" != "$(cat "$rows")" ]; then
				printf '%s\n' "$next" >"$rows.tmp" && mv -f "$rows.tmp" "$rows"
				curl -s --unix-socket "$sock" -X POST http://localhost -d "reload-sync(cat $rows)+refresh-preview" >/dev/null || true
			else
				curl -s --unix-socket "$sock" -X POST http://localhost -d 'refresh-preview' >/dev/null || true
			fi
		done
	) &
	loop=$!
	sel=$(fzf --ansi --no-sort --layout=reverse --delimiter="$TAB" --with-nth=3.. \
		--track --id-nth=1 --listen="$sock" \
		--prompt='agents> ' --info=inline-right \
		--bind 'left-click:accept' \
		--bind "ctrl-x:execute($self kill {1} $rows)+reload-sync(cat $rows)" \
		--header 'enter/click: switch   ctrl-x: kill session/window' \
		--bind "load:pos($CUR_POS)+unbind(load)" \
		--preview "$self preview {2}" --preview-window='right,55%,border-left,<80(down,40%,border-top)' \
		<"$rows") || sel=""
	kill "$loop" 2>/dev/null
	rm -f "$rows" "$rows.tmp" "$sock"
	[ -n "$sel" ] || return 0
	sel=${sel#*"$TAB"}
	tmux switch-client -t "${sel%%"$TAB"*}"
}

# Nix substitutes the store path; a checkout falls back to the sibling file.
resume_lib="@resume_lib@"
[ -r "$resume_lib" ] || resume_lib="$(dirname "${BASH_SOURCE[0]}")/resume.sh"
# shellcheck disable=SC1090,SC1091
. "$resume_lib"

case "${1:-}" in
tick) cmd_tick "${2:-}" ;;
rows) cmd_rows ;;
preview) cmd_preview "${2:?target}" ;;
kill) cmd_kill "${2:?id}" "${3:?rows file}" ;;
navigator) cmd_navigator ;;
save) if resume_on; then cmd_save; fi ;;
restore) if resume_on; then cmd_restore; fi ;;
restore-begin) if resume_on; then cmd_restore_begin; fi ;;
resume-init) cmd_resume_init ;;
*)
	printf 'usage: tmux-agents {tick [quiet]|navigator|rows|preview TARGET|kill ID ROWS|save|restore|restore-begin|resume-init}\n' >&2
	exit 2
	;;
esac
