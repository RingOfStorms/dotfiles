# Check if ~/.config/environment exists and source all files within it
if [ -d "$HOME/.config/environment" ]; then
  for file in "$HOME/.config/environment/"*; do
    if [ -r "$file" ]; then
      if ! . "$file"; then
        echo "Failed to source $file"
      fi
    fi
  done
fi

# Basics
htop_psg () {
  htop -p $(psg $1 | awk '{r=r s $2;s=","} END{print r}')
}

htop_pid () {
  htop -p $(ps -ef | awk -v proc=$1 '$3 == proc { cnt++;if (cnt == 1) { printf "%s",$2 } else { printf ",%s",$2 } }')
}

psg_kill() {
  ps aux | grep -v "grep" | grep "${1}" | awk '{print $2}' | while read -r pid; do
    if [ -n "${pid}" ]; then
      echo "killing ${pid}"
      kill -9 "${pid}" &> /dev/null
    fi
  done
}

psg_terminate() {
  ps aux | grep -v "grep" | grep "${1}" | awk '{print $2}' | while read -r pid; do
    if [ -n "${pid}" ]; then
      echo "Terminating ${pid}"
      kill -15 "${pid}" &> /dev/null
    fi
  done
}

psg_skill() {
  ps aux | grep -v "grep" | grep "${1}" | awk '{print $2}' | while read -r pid; do
    if [ -n "${pid}" ]; then
      echo "Killing ${pid}"
      sudo kill -9 "${pid}" &> /dev/null
    fi
  done
}

mail_clear() {
  : > /var/mail/$USER
}

speedtest_fs () {
  dir=$(pwd)
  drive=$(df -h ${dir} | awk 'NR==2 {print $1}')
  echo Testing read speeds on drive ${drive}
  sudo hdparm -Tt ${drive}
  test_file=$(date +%u%m%d)
  test_file="${dir}/speedtest_fs_${test_file}"
  echo
  echo Testing write speeds into test file: ${test_file}
  dd if=/dev/zero of=${test_file} bs=8k count=10k; rm -f ${test_file}
}

speedtest_internet () {
  speedtest-cli
}

# git
getdefault () {
  git remote show origin | grep "HEAD branch" | sed 's/.*: //'
}

master () {
  git stash
  git checkout $(getdefault)
  pull
}

mp () {
  master
  prunel
}

pullmaster () {
  git pull origin $(getdefault)
}

push () {
  B=$(git branch | sed -n -e 's/^\* \(.*\)/\1/p')
  git pull origin $B
  git push origin $B --no-verify
}

pull () {
  git fetch
  B=$(git branch | sed -n -e 's/^\* \(.*\)/\1/p')
  git pull origin $B
}

forcepush () {
  B=$(git branch | sed -n -e 's/^\* \(.*\)/\1/p')
  git push origin $B --force
}

remote_branches () {
  git branch -a | grep 'remotes' | grep -v -E '.*(HEAD|${DEFAULT})' | cut -d'/' -f 3-
}

local_branches () {
  git branch -a | grep -v 'remotes' | grep -v -E '.*(HEAD|${DEFAULT})' | grep -v '^*' |  cut -d' ' -f 3-
}

prunel () {
  git fetch
  git remote prune origin

  for local in $(local_branches); do
    in=false
    for remote in $(remote_branches); do
      if [[ ${local} = ${remote} ]]; then
        in=true
      fi
    done;
    if [[ $in = 'false' ]]; then
      git branch -D ${local}
    else
      echo 'Skipping branch '${local}
    fi
  done;
}

branch() {
  local branch_name
  branch_name=$1
  if [ -z "$branch_name" ]; then
    echo "Usage: branch <name>" >&2
    return 1
  fi

  # Use XDG_DATA_HOME or default to ~/.local/share
  local xdg=${XDG_DATA_HOME:-$HOME/.local/share}
  local repo_dir
  # Determine the git common dir (points into the main repo's .git)
  local common_dir
  common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || {
    echo "Not inside a git repository." >&2
    return 1
  }
  # Make common_dir absolute if it's relative
  if [ "${common_dir#/}" = "$common_dir" ]; then
    common_dir="$(pwd)/$common_dir"
  fi
  # repo_dir is the path before '/.git' in the common_dir (handles worktrees)
  repo_dir="${common_dir%%/.git*}"
  if [ -z "$repo_dir" ]; then
    echo "Unable to determine repository root." >&2
    return 1
  fi

  local repo_base
  repo_base=$(basename "$repo_dir")
  local repo_hash
  repo_hash=$(printf "%s" "$repo_dir" | sha1sum | awk '{print $1}')

  # If user asked for default or master, cd back to repo root on default branch
  local default_branch
  default_branch=$(getdefault 2>/dev/null || echo "")
  if [ "$branch_name" = "default" ] || [ "$branch_name" = "master" ] || [ "$branch_name" = "$default_branch" ]; then
    cd "$repo_dir" || return 0
    # git fetch
    # git checkout "$default_branch"
    # pull
    return 0
  fi

  # Ensure we have up-to-date remote info
  git fetch --all --prune

  # If branch exists remotely and not locally, create local branch tracking remote
  if git ls-remote --exit-code --heads origin "$branch_name" >/dev/null 2>&1; then
    if ! git show-ref --verify --quiet "refs/heads/$branch_name"; then
      git branch --track "$branch_name" "origin/$branch_name" 2>/dev/null || git branch "$branch_name" "origin/$branch_name"
    fi
  fi

  # Worktree path
  local wt_root
  wt_root="$xdg/git_worktrees/${repo_base}_${repo_hash}"
  local wt_path
  wt_path="$wt_root/$branch_name"

  mkdir -p "$wt_root"

  # If worktree already exists, cd to it
  if [ -d "$wt_path/.git" ] || [ -d "$wt_path" -a -d "$wt_path/.git" ]; then
    cd "$wt_path" || return 0
    return 0
  fi

  # If a worktree for this branch is already registered elsewhere, find it and cd
  local existing
  existing=$(git worktree list --porcelain 2>/dev/null | awk -v b="$branch_name" 'BEGIN{RS=""} $0 ~ "refs/heads/"b{for(i=1;i<=NF;i++) if ($i ~ /^worktree/) print $2 }')
  if [ -n "$existing" ]; then
    cd "$existing" || return 0
    return 0
  fi

  # Create the worktree
  mkdir -p "$wt_path"
  git worktree add -B "$branch_name" "$wt_path" "origin/$branch_name" 2>/dev/null || git worktree add "$wt_path" "$branch_name"
  cd "$wt_path" || return 0
}


from_master () {
  git checkout $(getdefault) $@
}

stash() {
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  local datetime
  datetime=$(date +"%Y-%m-%d_%H-%M")
  local default_label="${datetime}_${branch}"
  if [ -n "$ZSH_VERSION" ]; then
    read "label?Stash label [default: $default_label]: "
  else
    read -e -p "Stash label [default: $default_label]: " label
  fi
  label=${label:-$default_label}
  git stash push -m "$label"
}

pop() {
  local selection
  selection=$(git stash list | \
    fzf --prompt="Select stash to pop: " \
        --preview="git stash show -p \$(echo {} | awk -F: '{print \$1}') | bat --color always --paging=never --style=plain -l diff")
  [ -z "$selection" ] && echo "No stash selected." && return 1
  local stash_ref
  stash_ref=$(echo "$selection" | awk -F: '{print $1}')
  echo "Popping $stash_ref..."
  git stash pop "$stash_ref"
}

delstash() {
  local selection
  selection=$(git stash list | \
    fzf --prompt="Select stash to pop: " \
        --preview="git stash show -p \$(echo {} | awk -F: '{print \$1}') | bat --color always --paging=never --style=plain -l diff")
  [ -z "$selection" ] && echo "No stash selected." && return 1
  local stash_ref
  stash_ref=$(echo "$selection" | awk -F: '{print $1}')
  echo "About to delete $stash_ref."
  git stash drop "$stash_ref"
}

# nix
alias nixpkgs=nixpkg
nixpkg () {
  if [ $# -eq 0 ]; then
    echo "Error: No arguments provided. Please specify at least one package."
    return 1
  fi
  cmd="nix shell"
  for pkg in "$@"; do
    cmd="$cmd \"nixpkgs#$pkg\""
  done
  eval $cmd
}

# Marks some files as in "git" but they won't actually get pushed up to the git repo
# Usefull for `gintent .envrc flake.lock flake.nix` to add nix items required by flakes in a git repo that won't want flakes added
gintent() {
    for file in "$@"; do
        if [ -f "$file" ]; then
            git add --intent-to-add "$file"
            git update-index --assume-unchanged "$file"
            echo "Intent added for $file"
        else
            echo "File not found: $file"
        fi
    done
}
alias gintentnix="gintent .envrc flake.lock flake.nix"

gintent_undo() {
  for file in "$@"; do
    if [ -f "$file" ]; then
        git update-index --no-assume-unchanged "$file"
        echo "Intent removed for $file"
    else
        echo "File not found: $file"
    fi
  done
}
alias gintentnix_undo="gintent_undo .envrc flake.lock flake.nix"


# Aider
aider () {
  http_proxy="" all_proxy="" https_proxy="" AZURE_API_BASE=http://100.64.0.8 AZURE_API_VERSION=2025-01-01-preview AZURE_API_KEY=1 nix run "nixpkgs#aider-chat-full" -- aider --dark-mode --no-gitignore --no-check-update --no-auto-commits --model azure/gpt-4.1-2025-04-14 $@
}
