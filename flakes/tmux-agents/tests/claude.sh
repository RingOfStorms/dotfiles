#!/usr/bin/env bash
# Claude Code detection, state, session lookup and resume; tmux and the
# process table are stubbed. Requires bash, coreutils, util-linux.
set -euo pipefail
here=$(dirname "${BASH_SOURCE[0]}")
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export XDG_STATE_HOME="$root/state" CLAUDE_CONFIG_DIR="$root/claude"
TAB=$'\t'
mkdir -p "$root/run" "$CLAUDE_CONFIG_DIR/sessions" "$CLAUDE_CONFIG_DIR/projects/-r"
# The real detection/classification functions, without running the CLI.
eval "$(sed -n '/^agent_kind()/,/^}/p;/^classify()/,/^}/p;/^classify_claude()/,/^}/p;/^agent_label()/,/^}/p' "$here/../tmux-agents.sh")"
# shellcheck source=../resume.sh
. "$here/../resume.sh"

runtime_dir() { printf '%s/run' "$root"; }
field() { printf '%s' "$1"; }
opt() { printf '%s' "$2"; }
load_ps() { :; }
fail=0
check() { # label expected actual
	if [ "$2" = "$3" ]; then printf 'PASS %s\n' "$1"; else printf 'FAIL %s: expected [%s] got [%s]\n' "$1" "$2" "$3" >&2 && fail=1; fi
}

screen=""
sent="$root/sent"
pane_cmd=bash
tmux() {
	case "$1" in
	capture-pane) printf '%s\n' "$screen" ;;
	list-panes) printf '%s' "$fixture_panes" ;;
	show-option) printf '/bin/bash' ;;
	display-message)
		case "${*: -1}" in
		'#{pane_pid}') printf '100' ;;
		'#{pane_current_command}') printf '%s' "$pane_cmd" ;;
		esac
		;;
	send-keys) shift 3 && [ "$1" != -l ] || shift; printf '%s|' "$@" >>"$sent" ;;
	*) return 1 ;;
	esac
}

# --- detection and labels
k() { agent_kind "$1" "$2" && printf '%s' "$REPLY"; }
check 'idle title + claude' claude "$(k '✳ Fix bug' claude)"
check 'spinner title under nono' claude "$(k '⠂ Fix bug' nono)"
check 'nix wrapper without title' claude "$(k 'josh@host' .claude-wrapped)"
check 'stale claude title on a shell' '' "$(k '✳ Fix bug' zsh)"
check 'omp still omp' omp "$(k 'π > x' nono)"
lbl() { agent_label claude "$1" && printf '%s' "$REPLY"; }
check 'label from title' 'Fix bug' "$(lbl '⠐ Fix bug')"
check 'default title label' claude "$(lbl '✳ Claude Code')"

# --- state
st() { screen=$2 && classify claude "$1" %1 && printf '%s' "$REPLY"; }
check 'working spinner' working "$(st '⠂ Fix bug' $'● Reading files…\n\n> \n  ? for shortcuts')"
check 'idle' idle "$(st '✳ Fix bug' $'● Done.\n\n> \n  ? for shortcuts')"
check 'bash permission prompt' input "$(st '⠂ Fix bug' $' Bash command\n   rm -rf build\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n Esc to cancel · Tab to amend')"
check 'edit permission in box' input "$(st '✳ Fix bug' $'│ Do you want to make this edit to a.go?\n│ ❯ 1. Yes\n│   2. No')"
check 'quoted prompt text in chat is not input' idle "$(st '✳ Fix bug' $'● The tool asks "Do you want to proceed?" first.\n\n> \n  ? for shortcuts')"

# --- session lookup via pid file
ps_children=([100]="200 " [200]="300 ")
ps_comm=([100]=bash [200]=nono [300]=.claude-wrapped)
if session_for_pane 100; then r=0; else r=$?; fi
check 'no pid file yet: unresolved' 1 "$r"
check 'kind found' claude "$found_kind"
printf '{"pid":300,"sessionId":"aaaaaaaa-1111-2222-3333-444444444444","cwd":"/r"}' >"$CLAUDE_CONFIG_DIR/sessions/300.json"
session_for_pane 100 && check 'session from pid file' aaaaaaaa-1111-2222-3333-444444444444 "$REPLY"
printf '{\n  "pid": 300,\n  "sessionId": "bbbbbbbb-1111-2222-3333-444444444444"\n}' >"$CLAUDE_CONFIG_DIR/sessions/300.json"
session_for_pane 100 && check 'pid file follows /resume, pretty JSON' bbbbbbbb-1111-2222-3333-444444444444 "$REPLY"

# --- save then restore
mkdir -p "$state_dir"
fixture_panes="t${TAB}0${TAB}1${TAB}100${TAB}nono${TAB}✳ Fix bug"
cmd_save
check 'save writes claude row' "t${TAB}0${TAB}1${TAB}claude${TAB}bbbbbbbb-1111-2222-3333-444444444444${TAB}live" "$(cat "$resume_file")"

ps_children=() ps_comm=([100]=bash) # after reboot: just a shell
: >"$CLAUDE_CONFIG_DIR/projects/-r/bbbbbbbb-1111-2222-3333-444444444444.jsonl"
cmd_restore
check 'restore sends claude --resume' 'claude --resume bbbbbbbb-1111-2222-3333-444444444444|Enter|' "$(cat "$sent" 2>/dev/null)"
check 'row pending after send' pending "$(cut -f6 "$resume_file")"

rm "$CLAUDE_CONFIG_DIR/projects/-r/bbbbbbbb-1111-2222-3333-444444444444.jsonl"
: >"$sent"
cmd_restore
check 'missing transcript drops row' '' "$(cat "$resume_file")"
check 'nothing sent for missing transcript' '' "$(cat "$sent")"

exit $fail
