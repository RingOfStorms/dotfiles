# tmux-agents

Agent awareness for a plain tmux setup, with no plugins inside the harnesses.

- **Navigator** (`prefix + w`, or tap the session badge / agent counts in the status bar): fzf popup grouping sessions as repo → session (branch, worktree flag) → windows, with agent glyphs and a live `capture-pane` preview (below the list on narrow screens). Grouping is recomputed from git, so a session that `cd`s into a worktree of another repo moves under that repo on its own. Sessions outside git show under `other`. The open list refreshes itself every second (fzf `--listen` + `reload-sync`, only when rows changed; `--track --id-nth` keeps the cursor on the same row). A single click/tap on a row switches to it. `ctrl-x` asks `[y/N]` and kills the session or window under the cursor (killing the session you are in moves you to your last session first).
- **State**: a status-line `#()` tick (every `status-interval`, at most 2s) reads `#{pane_title}` for all panes and sets `@agent_state` (`working|idle|input`) per pane, `@agent_unseen` when an agent finishes or asks for input while you aren't looking at it, and `@agent_win` (`input|done`) per window. Unseen clears when you view the pane (selection hooks re-run the tick immediately).
- **Status**: segment prepended to `status-right` (`! n` needs input, `⠿ n` working, `● n` done unseen); non-current windows get a `!`/`●` marker in front of catppuccin's format.
- **Notifications** (when an agent finishes or needs input while you aren't looking): one master switch plus independent channels. `desktop` = notify-send on the tmux host; `message` = tmux message on every attached client (reaches ssh/mobile); `sound` = `off` | `local` (pw-play/paplay a file on the tmux host; separate done/needs-input sounds) | `bell` (terminal bell to each attached client, so an ssh/mobile client beeps or vibrates). Events in one tick are batched: one sound and one message.
- **Resume**: tmux-resurrect post-save writes `$XDG_STATE_HOME/tmux-agents/resume.tsv` mapping each agent pane to its omp session file (from omp's `~/.omp/agent/terminal-sessions/pts-N` breadcrumb). Post-restore runs `omp --resume=<file>` in each restored pane still sitting at a shell. Resurrect itself never restores omp (it isn't in `@resurrect-processes`).

## Detection

Nothing depends on process names or harness integrations (no herdr hints), so sandbox wrappers like `nono run ... -- omp` work unchanged: the title and the breadcrumb are both written by omp itself on the pane's own tty. Resume is typed into the interactive shell, so the `omp` alias (and its wrapper) is what relaunches the session.

omp titles itself `π <spinner> label` while working, `π > label` when idle and `π ! label` when blocked on an ask/approval prompt. Titles that don't start with `π` aren't agents. To add another harness, extend `classify` in `tmux-agents.sh`.

## Options

Home Manager: import `homeManagerModules.defaultEnabled` (on by default) or `homeManagerModules.default` (set `enable` yourself). Options: `ringofstorms.tmuxAgents.{enable,key,resume}` and `ringofstorms.tmuxAgents.notifications.{enable,desktop,message,sound,soundDone,soundInput,doneVolume,inputVolume}`. The module appends the plugin with `lib.mkAfter` so it loads after catppuccin/resurrect/continuum.

tmux options: `@tmux-agents-key` (`w`), `@tmux-agents-mouse` (`on`: status-left and agent-count taps open the navigator, replacing the default status-left click), `@tmux-agents-notify` (`on`, master), `@tmux-agents-notify-desktop` (`on`), `@tmux-agents-notify-message` (`off`), `@tmux-agents-notify-sound` (`local`; `off|local|bell`), `@tmux-agents-sound-done` / `@tmux-agents-sound-input` (file paths), `@tmux-agents-sound-done-volume` / `@tmux-agents-sound-input-volume` (`15` / `90`, percent), `@tmux-agents-resume` (`on`), `@tmux-agents-resume-command` (`omp --resume=`), `@tmux-agents-interval` (`2`), `@tmux-agents-navigator-interval` (`1`), `@tmux-agents-popup-width`/`-height` (`85%`/`75%`). All are read at event time, so `tmux set -g @tmux-agents-notify off` takes effect immediately.

CLI (`bin/tmux-agents` in the plugin dir): `tick [quiet]`, `navigator`, `rows`, `preview TARGET`, `kill ID ROWS`, `save`, `restore`.
