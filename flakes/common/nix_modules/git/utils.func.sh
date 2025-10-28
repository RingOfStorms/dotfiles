# git
getdefault () {
  git remote show origin | grep "HEAD branch" | sed 's/.*: //'
}

master () {
  branch $(getdefault)
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
  git for-each-ref --format='%(refname:short)' refs/remotes 2>/dev/null | sed 's#^[^/]*/##' | grep -v '^HEAD$' || true
}

local_branches () {
  git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null || true
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
  git stash push -u -k -m "$label"
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
