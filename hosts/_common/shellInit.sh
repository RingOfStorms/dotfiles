# basics
htop_psg () {
  htop -p $(psg $1 | awk '{r=r s $2;s=","} END{print r}')
}

htop_pid () {
  htop -p $(ps -ef | awk -v proc=$1 '$3 == proc { cnt++;if (cnt == 1) { printf "%s",$2 } else { printf ",%s",$2 } }')
}

kill_psg() {
  PIDS=$(ps aux | grep -v "grep" | grep ${1} | awk '{print $2}')
  echo Killing ${PIDS}
  for pid in ${PIDS}; do
    kill -9 ${pid} &> /dev/null
  done
}

term_psg() {
  PIDS=$(ps aux | grep -v "grep" | grep ${1} | awk '{print $2}')
  echo Terminating ${PIDS}
  for pid in ${PIDS}; do
    kill -15 ${pid} &> /dev/null
  done
}

skill_psg() {
  PIDS=$(ps aux | grep -v "grep" | grep ${1} | awk '{print $2}')
  echo Quitting ${PIDS}
  for pid in ${PIDS}; do
    sudo kill -9 ${pid} &> /dev/null
  done;
}

mail_clear() {
  : > /var/mail/$USER
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
