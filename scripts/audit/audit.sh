#!/usr/bin/env bash
#
# nixos-audit — scan flake locks and built closures for security-relevant issues.
#
# Two layers:
#   1. Staleness scan  — flags stale / off-branch nixpkgs inputs across every
#                        flake.lock in the repo, plus a nixpkgs rev-drift report.
#                        (uses DeterminateSystems/flake-checker, fetched at runtime)
#   2. CVE scan        — matches known CVEs against the package versions in a
#                        built system closure, via `vulnix`.
#                        Default: the current host. `--all`: every deployable host.
#
# vulnix only matches nixpkgs-derived store paths — third-party git inputs get no
# CVE coverage, so the staleness scan + rev-drift report are the safety net there.
#
# Usage:
#   nixos-audit                      # staleness (all locks) + CVE (current host)
#   nixos-audit --all                # staleness + CVE for every deployable host
#   nixos-audit --host lio           # staleness + CVE for one host
#   nixos-audit --stale-only         # only the staleness / rev-drift passes
#   nixos-audit --cve-only           # only the CVE pass
#   nixos-audit --whitelist f.toml   # vulnix CVE whitelist (suppress accepted CVEs)
#   nixos-audit --build-remote       # allow building foreign-arch / remote hosts
#
set -uo pipefail

# ── Defaults ────────────────────────────────────────────────────────
MODE_STALE=1
MODE_CVE=1
TARGET_HOST=""
DO_ALL=0
WHITELIST=""
BUILD_REMOTE=0

# Track worst finding for exit code: 0 ok, 1 warnings, 2 vulnerabilities.
EXIT_CODE=0
# Count of locks whose top-level nixpkgs is older than the staleness threshold.
STALE_FOUND=0

# ── Colors (only if stdout is a tty) ────────────────────────────────
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'
  C_BLU=$'\033[34m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_BOLD=""; C_RST=""
fi

note()  { echo "${C_BLU}::${C_RST} $*"; }
# Use if/then (not `(( )) &&`) so a false arithmetic test can't trip `set -e`.
warn()  { echo "${C_YEL}!!${C_RST} $*"; if (( EXIT_CODE < 1 )); then EXIT_CODE=1; fi; }
vuln()  { echo "${C_RED}XX${C_RST} $*"; EXIT_CODE=2; }
ok()    { echo "${C_GRN}ok${C_RST} $*"; }
hdr()   { echo; echo "${C_BOLD}=== $* ===${C_RST}"; }

# Print each input line indented by 6 spaces (avoids sed/SC2001).
indent() { while IFS= read -r _l; do printf '      %s\n' "$_l"; done; }

usage() {
  # Print the leading comment block (drop shebang/preamble and the "# " prefix).
  local started=0
  while IFS= read -r _l; do
    case "$_l" in
      "#") started=1; echo ;;                        # bare marker -> blank
      "# "*) started=1; printf '%s\n' "${_l#\# }" ;; # comment line
      *) if [[ $started -eq 1 ]]; then break; fi ;;  # end once block started
    esac
  done < "$0"
  exit "${1:-0}"
}

# ── Arg parsing ─────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)          DO_ALL=1; shift ;;
    --host)         TARGET_HOST="${2:?--host needs a name}"; shift 2 ;;
    --stale-only)   MODE_CVE=0; shift ;;
    --cve-only)     MODE_STALE=0; shift ;;
    --whitelist)    WHITELIST="${2:?--whitelist needs a path}"; shift 2 ;;
    --build-remote) BUILD_REMOTE=1; shift ;;
    -h|--help)      usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 1 ;;
  esac
done

# ── Locate repo root ────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT" || { echo "cannot cd to repo root" >&2; exit 2; }

CURRENT_SYSTEM="$(nix eval --impure --raw --expr 'builtins.currentSystem' 2>/dev/null || echo unknown)"

# ════════════════════════════════════════════════════════════════════
# Layer 1 — Staleness scan
# ════════════════════════════════════════════════════════════════════
staleness_scan() {
  hdr "Staleness scan (flake-checker)"

  mapfile -t LOCKS < <(find . -name flake.lock -not -path './.direnv/*' | sort)
  if [[ ${#LOCKS[@]} -eq 0 ]]; then
    warn "no flake.lock files found"
    return
  fi
  note "found ${#LOCKS[@]} lock file(s)"

  # Resolve flake-checker to a store path once so we don't re-fetch per lock.
  # flake-checker's age threshold is a fixed 30 days; it always checks that.
  note "resolving flake-checker (github:DeterminateSystems/flake-checker)"
  local fcdir fc
  fcdir="$(nix build --no-link --print-out-paths \
    github:DeterminateSystems/flake-checker 2>/dev/null || true)"
  fc="${fcdir}/bin/flake-checker"
  if [[ -z "$fcdir" || ! -x "$fc" ]]; then
    warn "could not resolve flake-checker; skipping staleness scan"
    return
  fi

  for lock in "${LOCKS[@]}"; do
    local out rc
    # --fail-mode makes it exit 1 on any issue so we can detect findings.
    # `|| rc=$?` keeps errexit from killing the loop on expected nonzero exits.
    rc=0
    out="$("$fc" --no-telemetry --check-supported --check-outdated \
      --check-owner --fail-mode "$lock" 2>&1)" || rc=$?

    if [[ $rc -eq 0 ]]; then
      ok "$lock"
    elif [[ "$out" == *"no nixpkgs dependency found"* ]]; then
      # Sub-flake whose nixpkgs input isn't keyed "nixpkgs" (e.g. follows).
      note "$lock (no direct nixpkgs input — skipped)"
    else
      warn "$lock"
      printf '%s\n' "$out" | indent
    fi
  done
}

# Resolve a lock's TOP-LEVEL nixpkgs (the one the flake itself declares as its
# `nixpkgs` input), printing "rev<TAB>lastModified<TAB>ref".
#
# IMPORTANT: do NOT read `.nodes.nixpkgs` directly. In a nested flake.lock the
# node literally NAMED "nixpkgs" is often a *transitive* dependency of a
# sub-flake, not the system's nixpkgs. The correct path is:
#   root.inputs.nixpkgs  ->  <node name>  ->  that node's .locked
# (root.inputs.<x> may be a string node-name or a [follows] path array.)
resolve_nixpkgs() {
  jq -r '
    # root.inputs.nixpkgs is either a node-name string, or a "follows" path
    # (array). For a follows array the last element is the input key on the
    # followed node; we just take the last element as the node name, which holds
    # for the common single-level "follows" used here.
    (.nodes.root.inputs.nixpkgs) as $ref
    | (if   ($ref | type) == "string" then $ref
       elif ($ref | type) == "array"  then $ref[-1]
       else null end) as $name
    | ($name | if . == null then null else $name end) as $name
    | (if $name == null then null else .nodes[$name].locked end) as $l
    | (if $name == null then null else .nodes[$name].original.ref end) as $ref2
    | if ($l == null or $l == {}) then "none\t0\tnone"
      else "\($l.rev // "none")\t\($l.lastModified // 0)\t\($ref2 // "?")"
      end
  ' "$1" 2>/dev/null || printf 'none\t0\tnone\n'
}

# nixpkgs rev-drift + age report — surfaces stale/divergent SYSTEM nixpkgs.
revdrift_report() {
  hdr "nixpkgs drift + age report (top-level input per lock)"
  printf '  %-46s %-12s %-14s %s\n' "lock" "rev" "branch" "age"

  declare -A rev_count
  local now; now="$(date +%s)"
  while IFS= read -r lock; do
    local line rev lm ref age agestr
    line="$(resolve_nixpkgs "$lock")"
    rev="$(printf '%s' "$line" | cut -f1)"
    lm="$(printf '%s' "$line" | cut -f2)"
    ref="$(printf '%s' "$line" | cut -f3)"

    if [[ "$rev" == "none" || -z "$rev" ]]; then
      printf '  %-46s %-12s %-14s %s\n' "$lock" "none" "-" "-"
      continue
    fi

    age=$(( (now - lm) / 86400 ))
    agestr="${age}d"
    # Flag anything older than 30 days as stale (our own check; flake-checker's
    # age heuristic is unreliable for release branches).
    if (( age > 30 )); then
      printf '  %-46s %-12s %-14s %s  %s\n' \
        "$lock" "${rev:0:10}" "$ref" "$agestr" "${C_YEL}STALE${C_RST}"
      STALE_FOUND=$(( STALE_FOUND + 1 ))
    else
      printf '  %-46s %-12s %-14s %s\n' "$lock" "${rev:0:10}" "$ref" "$agestr"
    fi
    rev_count["$rev"]=$(( ${rev_count["$rev"]:-0} + 1 ))
  done < <(find . -name flake.lock -not -path './.direnv/*' | sort)

  local distinct=${#rev_count[@]}
  echo
  if (( STALE_FOUND > 0 )); then
    warn "${STALE_FOUND} lock(s) have a nixpkgs input older than 30 days"
  fi
  if (( distinct > 1 )); then
    note "${distinct} distinct top-level nixpkgs revisions across locks (some drift is normal across unstable/release branches)"
  else
    ok "all locks share a single top-level nixpkgs revision"
  fi
}

# ════════════════════════════════════════════════════════════════════
# Layer 2 — CVE scan (vulnix)
# ════════════════════════════════════════════════════════════════════

# Build-only artifacts that are never in a runtime closure. Used as a fallback
# classifier when we have no concrete runtime root to compare against.
BUILD_ARTIFACT_RE='(-bootstrap|-vendor|-vendor-staging|-go-modules|-npm-deps|-source|-source-unsecvars|-binlore|-env|\.cabal$|\.tar$)'

# Print the package basenames (store hash stripped) of a path's RUNTIME closure.
# This is ground truth for "what actually runs" — far more accurate than the
# name-regex heuristic, because it excludes build-time-only dependencies
# (compilers, vendored sources, etc.) that vulnix --system otherwise reports.
runtime_names() {
  nix-store -q --requisites "$1" 2>/dev/null | sed 's|/nix/store/[a-z0-9]*-||'
}

# Run vulnix and classify findings into "in runtime closure" (actionable) vs
# "build-only" (not running). Args:
#   $1 label, $2 runtime-root path (or "" if none), $3.. vulnix args
#
# vulnix's exit code is ambiguous (non-zero for BOTH findings and errors), so we
# drive everything off --json: a parseable array = success; unparseable = error.
run_vulnix() {
  local label="$1" runtime_root="$2"; shift 2
  local args=("$@")
  if [[ -n "$WHITELIST" ]]; then args+=(--whitelist "$WHITELIST"); fi

  local json
  json="$(vulnix --json "${args[@]}" 2>/dev/null || true)"

  local total
  total="$(printf '%s' "$json" | jq 'length' 2>/dev/null || echo "")"
  if [[ -z "$total" ]]; then
    warn "${label}: vulnix did not complete (error / network / bad path)"
    return
  fi
  if [[ "$total" -eq 0 ]]; then
    ok "${label}: no known vulnerabilities"
    return
  fi

  # Partition findings into runtime vs build-only.
  local runtime_json rtfile="" method
  if [[ -n "$runtime_root" && -e "$runtime_root" ]]; then
    # Ground truth: intersect with the actual runtime closure.
    method="runtime closure"
    rtfile="$(mktemp)"
    runtime_names "$runtime_root" | sort -u > "$rtfile"
    runtime_json="$(printf '%s' "$json" | jq --rawfile rt "$rtfile" '
      ($rt | split("\n") | map(select(length>0))) as $names
      | ($names | INDEX(.)) as $set
      | [ .[]
          | . as $f
          | select(
              ($set[$f.name] != null)                       # exact match
              or any($names[]; startswith($f.name + "-"))   # multi-output (-lib,-bin,…)
            )
        ]
    ' 2>/dev/null || printf '%s' "$json")"
    rm -f "$rtfile"
  else
    # Fallback: name-regex heuristic.
    method="name heuristic"
    runtime_json="$(printf '%s' "$json" \
      | jq --arg re "$BUILD_ARTIFACT_RE" '[.[] | select(.name | test($re) | not)]')"
  fi

  local runtime_count build_count
  runtime_count="$(printf '%s' "$runtime_json" | jq 'length')"
  build_count=$(( total - runtime_count ))

  note "${label}: ${total} flagged → ${runtime_count} in runtime closure, ${build_count} build-only (via ${method})"
  note "actionable runtime findings by CVSS:"

  local top=40
  printf '%s' "$runtime_json" | jq -r --argjson top "$top" '
    ( [.[] | {name, max: ([.cvssv3_basescore[]?] | max // 0), n: (.affected_by | length)}]
      | sort_by(-.max) ) as $rows
    | ($rows[:$top][]
       | "      \(.max|tostring|(. + "    ")[0:5]) \(.n) CVE(s)  \(.name)"),
      (if ($rows|length) > $top
       then "      … and \(($rows|length) - $top) more"
       else empty end)
  '

  if [[ "$runtime_count" -gt 0 ]]; then
    vuln "${label}: ${runtime_count} runtime package(s) with known advisories"
  else
    ok "${label}: no runtime advisories (only build-time artifacts flagged)"
  fi
}

# Run vulnix against an already-built store path (a system toplevel).
vulnix_closure() {
  local path="$1" label="$2"
  note "vulnix scanning closure for ${label}"
  run_vulnix "$label" "$path" --closure "$path"
}

# Scan the live running system, classified against its runtime closure.
cve_current() {
  hdr "CVE scan — current host (live system)"
  note "vulnix --system (this may download the CVE database on first run)"
  run_vulnix "current host" "/run/current-system" --system
}

# Build one host's toplevel and scan its closure.
cve_host() {
  local host="$1"
  hdr "CVE scan — host ${host}"

  # Verify the host is registered, then resolve its flake path.
  local known flakepath hostsys
  known="$(nix eval --impure --expr \
    "(import $REPO_ROOT/hosts/fleet.nix).hosts ? ${host}" 2>/dev/null || true)"
  if [[ "$known" != "true" ]]; then
    warn "${host}: not in fleet registry (hosts/fleet.nix); skipping"
    return
  fi
  flakepath="$(nix eval --raw --impure --expr \
    "(import $REPO_ROOT/hosts/fleet.nix).hosts.${host}.flakePath or \"hosts/${host}\"" \
    2>/dev/null || true)"
  if [[ -z "$flakepath" ]]; then
    warn "${host}: could not resolve flake path; skipping"
    return
  fi

  hostsys="$(nix eval --raw \
    "$REPO_ROOT/${flakepath}#nixosConfigurations.${host}.pkgs.stdenv.hostPlatform.system" \
    2>/dev/null || true)"
  hostsys="${hostsys:-$CURRENT_SYSTEM}"

  if [[ "$hostsys" != "$CURRENT_SYSTEM" && "$BUILD_REMOTE" -eq 0 ]]; then
    warn "${host}: system ${hostsys} != current ${CURRENT_SYSTEM}; skipping (use --build-remote)"
    return
  fi

  note "building ${host} toplevel from ${flakepath}"
  local result rc=0
  result="$(nix build --no-link --print-out-paths \
    "$REPO_ROOT/${flakepath}#nixosConfigurations.${host}.config.system.build.toplevel" \
    2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "${host}: build failed; skipping CVE scan"
    printf '%s\n' "$result" | tail -n5 | indent
    return
  fi
  vulnix_closure "$result" "$host"
}

# Scan every deployable host (the beefy-machine mode).
cve_all() {
  hdr "CVE scan — all deployable hosts"
  local hosts
  hosts="$(nix eval --json --impure --expr \
    "builtins.attrNames (import $REPO_ROOT/hosts/fleet.nix).deployableHosts" \
    2>/dev/null | jq -r '.[]' 2>/dev/null || true)"
  if [[ -z "$hosts" ]]; then
    warn "could not enumerate deployable hosts from fleet.nix"
    return
  fi
  local host_arr=()
  mapfile -t host_arr <<< "$hosts"
  note "hosts: ${host_arr[*]}"
  local h
  for h in "${host_arr[@]}"; do
    cve_host "$h"
  done
}

# ── Pre-flight ──────────────────────────────────────────────────────
if [[ -n "$WHITELIST" && ! -f "$WHITELIST" ]]; then
  echo "whitelist not found: $WHITELIST" >&2; exit 2
fi

note "repo: ${REPO_ROOT}"
note "current system: ${CURRENT_SYSTEM}"

# ── Run ─────────────────────────────────────────────────────────────
if [[ $MODE_STALE -eq 1 ]]; then
  staleness_scan
  revdrift_report
fi

if [[ $MODE_CVE -eq 1 ]]; then
  if [[ $DO_ALL -eq 1 ]]; then
    cve_all
  elif [[ -n "$TARGET_HOST" ]]; then
    cve_host "$TARGET_HOST"
  else
    cve_current
  fi
fi

# ── Summary ─────────────────────────────────────────────────────────
hdr "Summary"
case "$EXIT_CODE" in
  0) ok   "no issues found" ;;
  1) warn "staleness/config warnings found — review above" ;;
  2) vuln "vulnerabilities found — review above" ;;
esac
exit "$EXIT_CODE"
