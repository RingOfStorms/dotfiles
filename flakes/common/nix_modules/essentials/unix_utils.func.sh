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

peedtest_fs () {
  dir=$(pwd)
  drive=$(df -h "${dir}" | awk 'NR==2 {print $1}')
  echo "Testing filesystem on: ${dir}"
  echo "Underlying device:     ${drive}"
  echo

  test_file="${dir}/speedtest_fs_$(date +%u%m%d).fio"
  file_size=1G    # size of the test file
  runtime=5       # seconds per test

  cleanup() {
    if [ -n "${test_file:-}" ] && [ -f "${test_file}" ]; then
      echo
      echo "Cleaning up test file: ${test_file}"
      rm -f "${test_file}"
    fi
  }

  # Ensure cleanup on normal exit, Ctrl+C, etc.
  trap cleanup EXIT INT TERM

  echo "Creating test file (${file_size}) at: ${test_file}"
  fio --name=precreate \
      --filename="${test_file}" \
      --rw=write \
      --bs=1M \
      --size="${file_size}" \
      --iodepth=16 \
      --direct=1 \
      --numjobs=1 \
      --group_reporting >/dev/null 2>&1

  echo
  echo "=== Sequential write test (${runtime}s) ==="
  fio --name=seqwrite \
      --filename="${test_file}" \
      --rw=write \
      --bs=1M \
      --size="${file_size}" \
      --iodepth=16 \
      --direct=1 \
      --numjobs=1 \
      --time_based \
      --runtime="${runtime}" \
      --group_reporting

  echo
  echo "=== Sequential read test (${runtime}s) ==="
  fio --name=seqread \
      --filename="${test_file}" \
      --rw=read \
      --bs=1M \
      --size="${file_size}" \
      --iodepth=16 \
      --direct=1 \
      --numjobs=1 \
      --time_based \
      --runtime="${runtime}" \
      --group_reporting
}

speedtest_internet () {
  speedtest-cli
}
