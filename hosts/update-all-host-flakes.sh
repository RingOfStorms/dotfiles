#!/usr/bin/env bash
# Update the given flake inputs in every host flake under this directory.
#   ./update-all-host-flakes.sh common containers beszel
# Inputs a host doesn't have (per its flake.lock root inputs) are skipped.

set -uo pipefail

if [ $# -eq 0 ]; then
  echo "usage: $0 <input> [input...]" >&2
  exit 2
fi

cd "$(dirname "$0")" || exit 1

mapfile -t HOST_DIRS < <(find . -type f -name 'flake.nix' -not -path '*/.*' -printf '%h\n' | sort -u)

TMP_RESULTS="$(mktemp -t update-host-flakes.XXXXXX)"
trap 'rm -f "$TMP_RESULTS"' EXIT

# Root input names of a flake.lock, one per line.
root_inputs() {
  perl -MJSON::PP -0777 -ne 'my $l = decode_json($_); print "$_\n" for keys %{ $l->{nodes}{ $l->{root} }{inputs} || {} }' "$1"
}

for dir in "${HOST_DIRS[@]}"; do
  (
    if [ ! -f "$dir/flake.lock" ]; then
      echo "SKIP:$dir:no flake.lock" >>"$TMP_RESULTS"
      exit 0
    fi
    have="$(root_inputs "$dir/flake.lock")"
    wanted=()
    for name in "$@"; do
      grep -qx -- "$name" <<<"$have" && wanted+=("$name")
    done
    if [ ${#wanted[@]} -eq 0 ]; then
      echo "SKIP:$dir:none of the inputs" >>"$TMP_RESULTS"
      exit 0
    fi
    echo "[START] $dir: ${wanted[*]}"
    if (cd "$dir" && nix flake update "${wanted[@]}"); then
      echo "OK:$dir:${wanted[*]}" >>"$TMP_RESULTS"
      echo "[OK]    $dir"
    else
      echo "FAIL:$dir:exit $?" >>"$TMP_RESULTS"
      echo "[FAIL]  $dir"
    fi
  ) &
done

wait

echo
echo "===== Summary ====="
for kind in OK SKIP FAIL; do
  n=$(grep -c "^$kind:" "$TMP_RESULTS")
  [ "$n" -gt 0 ] || continue
  echo "$kind ($n):"
  grep "^$kind:" "$TMP_RESULTS" | sort | awk -F':' '{print "  " $2 "  (" $3 ")"}'
done

grep -q '^FAIL:' "$TMP_RESULTS" && exit 1
exit 0
