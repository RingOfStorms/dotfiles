#!/usr/bin/env bash
set -euo pipefail

[ "${HERDR_ENV:-}" = 1 ] && [ "${HERDR_PLUGIN_EVENT:-}" = worktree.created ] || {
  printf 'Expected Herdr worktree.created plugin event\n' >&2
  exit 1
}
: "${HERDR_PLUGIN_EVENT_JSON:?Missing Herdr worktree event payload}"

# Herdr emits the event only once the checkout exists. The event envelope
# carries its worktree under data, not directly on the top-level object.
mapfile -d '' -t paths < <(jq -jr '
  if .event == "worktree_created" and .data.type == "worktree_created"
      and .data.worktree.is_linked_worktree == true
      and (.data.worktree.path | type) == "string"
  then .data.worktree.path + "\u0000" else empty end
' <<< "$HERDR_PLUGIN_EVENT_JSON")
[ "${#paths[@]}" -eq 1 ] || {
  printf 'Invalid or non-linked Herdr worktree.created event\n' >&2
  exit 1
}

wt_path=${paths[0]}
[ -d "$wt_path" ] || {
  printf 'Herdr worktree checkout does not exist: %s\n' "$wt_path" >&2
  exit 1
}
source "${HERDR_PLUGIN_ROOT:-$(dirname "${BASH_SOURCE[0]}")}/link_ignored.func.sh"
source "${HERDR_PLUGIN_ROOT:-$(dirname "${BASH_SOURCE[0]}")}/worktree_setup.sh"
# The plugin's cwd is its own directory; discover the root from the checkout.
repo_dir=$(git -C "$wt_path" rev-parse --path-format=absolute --git-common-dir)
repo_dir=${repo_dir%/.git}
repo_dir=$(builtin cd -P -- "$repo_dir" && pwd -P)
_branch__setup_worktree "$repo_dir" "$wt_path"
