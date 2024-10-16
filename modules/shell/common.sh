# basics
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

checkout () {
  git fetch
  git checkout $1
  pull
}

from_master () {
  git checkout $(getdefault) $@
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

