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
