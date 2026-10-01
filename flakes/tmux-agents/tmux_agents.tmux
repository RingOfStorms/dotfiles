#!/usr/bin/env bash
# tmux-agents entry point. Load after catppuccin, resurrect and continuum:
# it decorates the status line and window formats those plugins built.
set -eu

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$CURRENT_DIR/bin/tmux-agents"

opt() {
	local v
	v=$(tmux show-option -gqv "$1")
	printf '%s' "${v:-$2}"
}

key=$(opt @tmux-agents-key w)
width=$(opt @tmux-agents-popup-width 85%)
height=$(opt @tmux-agents-popup-height 75%)
interval=$(opt @tmux-agents-interval 2)

# One tmux command string, parsed by tmux, reused for every trigger.
popup="display-popup -E -w '$width' -h '$height' -T ' agents ' '$bin navigator'"
tmux source-file - <<EOF
bind-key '$key' $popup
EOF
# Touch/mouse: tapping the session badge (status-left) or the agent counts
# opens the navigator. MouseUp keeps a tap from also starting a drag.
if [ "$(opt @tmux-agents-mouse on)" = on ]; then
	tmux unbind-key -T root MouseDown1StatusLeft 2>/dev/null || true
	tmux source-file - <<EOF
bind-key -T root MouseUp1StatusLeft $popup
bind-key -T root MouseUp1Status if-shell -F '#{==:#{mouse_status_range},agents}' { $popup }
EOF
fi

# Status tick. tmux caches #() output per command string, so one tick runs per
# interval regardless of client count; flock guards hook-triggered overlaps.
tick="#($bin tick)"
right=$(tmux show-option -gqv status-right)
case "$right" in
*"$bin tick"*) ;;
*) tmux set-option -g status-right "$tick$right" ;;
esac
current_interval=$(tmux show-option -gqv status-interval)
if [ -z "$current_interval" ] || [ "$current_interval" -gt "$interval" ]; then
	tmux set-option -g status-interval "$interval"
fi

# Highlight non-current windows holding an agent that needs input or finished
# unseen. Prepended so catppuccin's own styling of the window is untouched.
mark='#{?#{==:#{@agent_win},input},#[fg=red]#[bold]! #[default],#{?#{==:#{@agent_win},done},#[fg=green]● #[default],}}'
wfmt=$(tmux show-option -gqv window-status-format)
case "$wfmt" in
*'@agent_win'*) ;;
*) tmux set-option -g window-status-format "$mark$wfmt" ;;
esac

# Agents ring the terminal bell when they finish/ask; with monitor-bell, tmux's
# default bell style (reverse) inverts the whole tab on top of the marker
# above. Drop it unless the user chose their own style.
if [ "$(tmux show-option -gwqv window-status-bell-style)" = reverse ]; then
	tmux set-option -gw window-status-bell-style default
fi

# Viewing a pane clears its unseen mark immediately rather than on next tick.
for hook in after-select-window after-select-pane client-session-changed session-window-changed; do
	tmux set-hook -g "${hook}[87]" "run-shell -b '$bin tick quiet'"
done

# Resume agents through tmux-resurrect. The hooks are read when resurrect
# saves/restores, so setting them after resurrect loads is fine.
chain_hook() {
	local name=$1 cmd=$2 existing
	existing=$(tmux show-option -gqv "$name")
	case "$existing" in
	*"$bin"*) ;;
	'') tmux set-option -g "$name" "$cmd" ;;
	*) tmux set-option -g "$name" "$existing; $cmd" ;;
	esac
}
if [ "$(opt @tmux-agents-resume on)" = on ]; then
	chain_hook @resurrect-hook-post-save-all "$bin save"
	chain_hook @resurrect-hook-post-restore-all "$bin restore"
fi
