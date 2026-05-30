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

# ports_expose PORT [PORT...] - temporarily open TCP port(s) in the NixOS
# firewall by inserting accept rules at the top of the inet nixos-fw
# input-allow chain. Handy for quickly exposing an ssh -R tunnel without a
# rebuild. NOT persistent: rules are lost on reboot or `ports_reset`. For a
# durable rule add it to networking.firewall.allowedTCPPorts and rebuild.
ports_expose() {
  if [ "$#" -lt 1 ]; then
    echo "usage: ports_expose PORT [PORT...]" >&2
    return 1
  fi
  for port in "$@"; do
    case "$port" in
      ''|*[!0-9]*)
        echo "ports_expose: invalid port '$port'" >&2
        return 1
        ;;
    esac
    sudo nft insert rule inet nixos-fw input-allow tcp dport "$port" accept \
      && echo "ports_expose: opened tcp/$port"
  done
}

# ports_reset - drop all transient firewall changes and re-apply the
# declarative NixOS firewall configuration by restarting the firewall
# service. This undoes any `ports_expose` rules.
ports_reset() {
  echo "ports_reset: restarting firewall to restore declarative rules..."
  sudo systemctl restart firewall && echo "ports_reset: done"
}

speedtest_fs () {
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

  echo
  echo "=== Random read/write test (${runtime}s, 70% reads, 4k blocks) ==="
  fio --name=randrw \
      --filename="${test_file}" \
      --rw=randrw \
      --rwmixread=70 \
      --bs=4k \
      --size="${file_size}" \
      --iodepth=32 \
      --direct=1 \
      --numjobs=4 \
      --time_based \
      --runtime="${runtime}" \
      --group_reporting
}
