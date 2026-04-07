#!/usr/bin/env bash

set -uo pipefail

# Find all directories containing a flake.nix
mapfile -t FLAKE_DIRS < <(find . -type f -name 'flake.nix' -printf '%h\n' | sort -u)

if [ ${#FLAKE_DIRS[@]} -eq 0 ]; then
  echo "No flake.nix files found."
  exit 0
fi

TMP_RESULTS="$(mktemp -t update-all-flakes.XXXXXX)"

cleanup() {
  rm -f "$TMP_RESULTS"
}
trap cleanup EXIT

for dir in "${FLAKE_DIRS[@]}"; do
  (
    echo "[START] Updating $dir"
    if cd "$dir"; then
      if nix flake update; then
        echo "OK:$dir" >> "$TMP_RESULTS"
        echo "[OK]    $dir"
      else
        status=$?
        echo "FAIL:$dir:$status" >> "$TMP_RESULTS"
        echo "[FAIL]  $dir (exit $status)"
      fi
    else
      echo "FAIL:$dir:cd" >> "$TMP_RESULTS"
      echo "[FAIL]  $dir (could not cd)"
    fi
  ) &
done

wait

echo
echo "===== Summary ====="

fail_count=0
ok_count=0

while IFS= read -r line; do
  case "$line" in
    OK:*)
      ok_count=$((ok_count + 1))
      ;;
    FAIL:*)
      fail_count=$((fail_count + 1))
      ;;
  esac
done < "$TMP_RESULTS"

if [ "$ok_count" -gt 0 ]; then
  echo "Successful updates ($ok_count):"
  awk -F':' '/^OK:/ {print "  " $2}' "$TMP_RESULTS"
  echo
fi

if [ "$fail_count" -gt 0 ]; then
  echo "Failed updates ($fail_count):"
  awk -F':' '/^FAIL:/ {print "  " $2 " (exit " $3 ")"}' "$TMP_RESULTS"
  echo
fi

echo "Done. $ok_count succeeded, $fail_count failed."

# Non-blocking failures: script always exits 0
exit 0
