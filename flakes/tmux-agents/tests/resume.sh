#!/usr/bin/env bash
# Deterministic map-transition regressions; requires bash, coreutils, util-linux, sqlite3.
set -euo pipefail
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export XDG_STATE_HOME="$root/state" PI_CODING_AGENT_DIR="$root/omp" OPENCODE_DB="$root/opencode.db"
TAB=$'\t'
mkdir -p "$root/run" "$PI_CODING_AGENT_DIR"
# shellcheck source=../resume.sh
. "$(dirname "${BASH_SOURCE[0]}")/../resume.sh"

# Supply pane/process snapshots without touching the user's tmux server.
runtime_dir() { printf '%s/run' "$root"; }
field() { printf '%s' "$1"; }
opt() { printf '%s' "$2"; }
agent_kind() { REPLY=""; [[ $1 != 'π'* ]] || REPLY=omp; }
load_ps() { :; }
listing_status=0
fixture_panes="test${TAB}0${TAB}0${TAB}123${TAB}bash${TAB}plain-shell-title"
tmux() {
	case "$1" in
	list-panes) printf '%s' "$fixture_panes"; return "$listing_status" ;;
	show-option) printf '/bin/bash' ;;
	display-message) return 1 ;; # no restore target in the fixture
	*) return 1 ;;
	esac
}
process_status=2
process_kind=omp
process_ref="$root/session.jsonl"
session_for_pane() {
	found_kind=$process_kind REPLY=$process_ref
	return "$process_status"
}
mkdir -p "$state_dir"
row() { printf 'test\t0\t0\tomp\t%s\t%s' "$1" "$2"; }
seed() { row "$process_ref" "$1" >"$resume_file"; printf '\n' >>"$resume_file"; }
assert_map() {
	if [ "$(cat "$resume_file")" != "$1" ]; then
		printf 'FAIL %s\nExpected:\n%s\nActual:\n' "$label" "$1" >&2
		cat "$resume_file" >&2
		exit 1
	fi
	printf 'PASS %s\n' "$label"
}

label='failed listing preserves the entire map, even with partial stdout'
seed live
before=$(cat "$resume_file")
listing_status=1
if cmd_save; then exit 1; fi
assert_map "$before"

label='empty successful listing preserves the map'
listing_status=0
snapshot=$fixture_panes
fixture_panes=""
if cmd_save; then exit 1; fi
assert_map "$before"
fixture_panes=$snapshot

label='pending launch survives a shell title and no agent'
seed pending
cmd_save
assert_map "$(row "$process_ref" pending)"

label='unresolved startup requests retry without making pending disposable'
process_status=1
if cmd_save; then exit 1; fi
assert_map "$(row "$process_ref" pending)"
process_status=2
cmd_save
assert_map "$(row "$process_ref" pending)"

label='a resolved replacement session supersedes the previous pending mapping'
process_status=0
process_ref="$root/replacement.jsonl"
cmd_save
assert_map "$(row "$process_ref" live)"

label='a stopped agent receives a grace timestamp instead of disappearing'
process_status=2
cmd_save
IFS=$TAB read -r _ _ _ _ _ state <"$resume_file"
[[ $state == gone:* ]]
assert_map "$(row "$process_ref" "$state")"

label='an expired stopped agent is removed'
seed gone:1
cmd_save
assert_map ''

label='a closed pane address removes its pending mapping'
seed pending
fixture_panes="test${TAB}0${TAB}1${TAB}124${TAB}bash${TAB}plain-shell-title"
cmd_save
assert_map ''

# Keep the session row on disk while making the existence query fail. This
# exercises actual SQLite errors rather than equating no output with absence.
sqlite3 "$oc_db" "CREATE TABLE session_v2 (id TEXT PRIMARY KEY);
INSERT INTO session_v2 VALUES ('ses_existing');
ALTER TABLE session_v2 RENAME TO unavailable;"
label='failed SQLite lookup preserves an existing mapping as pending'
printf 'test\t0\t0\topencode\tses_existing\tlive\n' >"$resume_file"
cmd_restore
expected="test${TAB}0${TAB}0${TAB}opencode${TAB}ses_existing${TAB}pending"
assert_map "$expected"

label='a save cannot age out a mapping awaiting a successful lookup'
fixture_panes=$snapshot
cmd_save
assert_map "$expected"

label='successful lookup retains a session that still exists'
sqlite3 "$oc_db" 'ALTER TABLE unavailable RENAME TO session_v2;'
cmd_restore
assert_map "$expected"

label='only a successful empty lookup removes the missing session'
sqlite3 "$oc_db" "DELETE FROM session_v2 WHERE id = 'ses_existing';"
cmd_restore
assert_map ''
