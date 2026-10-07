# Git worktree helpers

The Git shell module loads `worktree_setup.func.sh`, `branch.func.sh`, `branchd.func.sh`, `link_ignored.func.sh` and `branching_setup.func.sh`. `branch <name> [base]` creates or reuses a Git worktree from anywhere inside a checkout and runs the configured worktree setup. `branch default` returns to the main checkout.

`branchdel [name]` removes the selected non-main worktree via Git, trying normal removal then `git worktree remove --force` for dirty checkouts, and force-deletes its local branch (`git branch -D`). Do not run `branchdel` on a checkout containing changes you want to keep.

`branching_setup` edits per-repository Git settings:

- `worktree.autolink` (multi-valued) selects ignored/untracked top-level entries to symlink from the main checkout; the existing `link_ignored` substring filter applies to link names. `BRANCH_AUTOLINK=1` enables the existing link helper's default behavior when no Git selection exists; `LINK_IGNORED_DEFAULTS` supplies its legacy defaults.
- `worktree.autocopy` (multi-valued) **explicitly** selects exact ignored/untracked top-level names to copy. It never copies all ignored files or takes defaults from `LINK_IGNORED_DEFAULTS`. A directory containing tracked files is refused. Configured copies run before links; an existing destination is never overwritten. The interactive wizard removes exact copy selections from autolink. `git config --local --add worktree.autocopy 'name'` works without `fzf`.
- `worktree.bootstrap` is `skip`, `auto` (pnpm/yarn/npm based on the checkout lockfile), or a shell command run in the new checkout. If unset, `BRANCH_BOOTSTRAP_CMD` overrides it, then `BRANCH_BOOTSTRAP` supplies `skip` by default. A set Git command overrides `BRANCH_BOOTSTRAP`; `BRANCH_BOOTSTRAP_CMD` takes highest priority. Package managers used by an `auto` or custom command must already be installed.

The wizard needs `fzf` for interactive selection; without it, it prints candidates and manual `git config` instructions, then still asks for the bootstrap command. An empty link/copy selection clears that setting, while Escape leaves it unchanged. A copy name selected in both settings wins.

Setup writes a `post-setup.done` marker inside the worktree-specific Git directory to prevent duplicate runs. The marker is written only after links, copies, and bootstrap succeed. If setup fails, `branch <name>` can reopen the worktree to retry; a failed bootstrap command can have partial effects and must be safe to rerun.
