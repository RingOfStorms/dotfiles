# Backup pusher tier (containers/BACKUP-PLAN.md §2.6, P4). Runs on a target:
# copies each offsite subject's local repo to <b2Repository>/svc-<s> (same
# repo password at both ends), prunes it with the B2 preset, measures it,
# records completeness, and executes `b2` clears. The B2 key is restricted
# to the `svc-` prefix, so nothing here can reach other repos in the bucket.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ringofstorms.backup.pusher;
  target = config.ringofstorms.backup.target;
  stateDir = "/var/lib/fleet-backup-target";
  repoKeysDir = "/var/lib/fleet-backup-target-keys/repo-keys";
  policyFile = "${stateDir}/policy.json";
  b2StatsFile = "${stateDir}/b2-stats.json";
  offsiteFile = "${stateDir}/offsite-b2.json";
  lockFile = "${stateDir}/pusher.lock";
  jq = "${pkgs.jq}/bin/jq";
  restic = "${pkgs.restic}/bin/restic";
  base = "s3:${cfg.endpoint}/${cfg.bucket}";

  # Shared prologue: B2 key from LoadCredential (b2env), a policy reply no
  # older than maxPolicyAge, subject-name check, per-subject password file.
  prologue = ''
    set -uo pipefail
    export RESTIC_CACHE_DIR=/var/cache/fleet-backup-target
    umask 0077
    envf="''${CREDENTIALS_DIRECTORY:-/nonexistent}/b2env"
    AWS_ACCESS_KEY_ID=$(${pkgs.gnused}/bin/sed -n 's/^AWS_ACCESS_KEY_ID=//p' "$envf" 2>/dev/null | tail -n1)
    AWS_SECRET_ACCESS_KEY=$(${pkgs.gnused}/bin/sed -n 's/^AWS_SECRET_ACCESS_KEY=//p' "$envf" 2>/dev/null | tail -n1)
    if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
      echo "pusher: no B2 key in ${cfg.b2EnvFile} (AWS_ACCESS_KEY_ID=/AWS_SECRET_ACCESS_KEY= lines)" >&2
      exit 1
    fi
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    if [ ! -r ${policyFile} ]; then
      echo "pusher: no policy reply yet; nothing to do" >&2
      exit 1
    fi
    age=$(( $(date +%s) - $(stat -c %Y ${policyFile}) ))
    if [ "$age" -gt ${toString cfg.maxPolicyAge} ]; then
      echo "pusher: policy reply is ''${age}s old (fleet-edge unreachable?); nothing to do" >&2
      exit 1
    fi
    validName() { case "$1" in ""|*[!a-z0-9-]*) return 1 ;; esac; }
    # pwFile S: a temp file holding svc-S's RESTIC_PASSWORD, or fail.
    pwFile() {
      local cred="''${CREDENTIALS_DIRECTORY:-/nonexistent}/repo_svc-$1" f
      [ -r "$cred" ] || return 1
      f=$(mktemp)
      ${pkgs.gnused}/bin/sed -n 's/^RESTIC_PASSWORD=//p' "$cred" | tail -n1 >"$f"
      [ -s "$f" ] || { rm -f "$f"; return 1; }
      echo "$f"
    }
    writeJson() { # FILE JSON: atomic 0600 write
      local t
      t=$(mktemp "$(dirname "$1")/.$(basename "$1").XXXXXX")
      printf '%s\n' "$2" >"$t" && mv -f "$t" "$1"
    }
  '';

  presetArgs = ''
    presetArgs() {
      case "$1" in
      ${lib.concatStrings (
        lib.mapAttrsToList (n: a: "  ${n}) echo ${lib.escapeShellArgs a} ;;\n") {
          short = [
            "--keep-daily"
            "3"
            "--keep-weekly"
            "2"
            "--keep-monthly"
            "1"
          ];
          standard = [
            "--keep-daily"
            "7"
            "--keep-weekly"
            "5"
            "--keep-monthly"
            "12"
            "--keep-yearly"
            "3"
          ];
          long = [
            "--keep-daily"
            "14"
            "--keep-weekly"
            "8"
            "--keep-monthly"
            "24"
            "--keep-yearly"
            "5"
          ];
        }
      )}
      esac
    }
    # b2Preset S: the reply's B2 preset (already `local`-resolved), else long.
    b2Preset() {
      local p
      p=$(${jq} -r --arg s "$1" '.retentionB2[$s] // empty' ${policyFile} 2>/dev/null || true)
      case "$p" in short|standard|long) echo "$p" ;; *) echo long ;; esac
    }
  '';

  # Per offsite subject: init (copied chunker params) if missing, copy,
  # B2 prune, raw size, completeness. b2-stats.json {s: {b2Bytes,
  # lastCopied, complete}} is merged into the heartbeat's stats.
  copyScript = pkgs.writeShellScript "fleet-backup-pusher-copy" ''
    ${prologue}
    ${presetArgs}
    # One lock for copy and clear (§2.6): a clear must never purge a repo
    # the copier is writing, and the copier must not re-add a cleared
    # subject's stats. The policy is re-read per subject under the lock.
    exec 9>${lockFile}
    flock 9
    rc=0
    stats='{}'
    [ -r ${b2StatsFile} ] && stats=$(cat ${b2StatsFile})
    offsite='{}'
    [ -r ${offsiteFile} ] && offsite=$(cat ${offsiteFile})
    for s in $(${jq} -r '.offsite // [] | .[]' ${policyFile}); do
      validName "$s" || { echo "copy: bad subject '$s'" >&2; rc=1; continue; }
      # Still offsite, no B2 clear pending (a clear sets offsite=false)?
      if ! ${jq} -e --arg s "$s" '((.offsite // []) | index($s)) != null and (.clears[$s] // "") != "b2"' ${policyFile} >/dev/null; then
        echo "copy: $s: no longer offsite or a B2 clear is pending, skipped"
        continue
      fi
      src=${target.dataDir}/svc-$s
      dst=${base}/svc-$s
      if [ ! -f "$src/config" ]; then
        echo "copy: $s: no local repo yet, skipped"
        continue
      fi
      pw=$(pwFile "$s") || { echo "copy: $s: no repo password on this target" >&2; rc=1; continue; }
      R() { ${restic} -r "$dst" --password-file "$pw" "$@" </dev/null; }

      R --no-lock cat config >/dev/null 2>&1
      e=$?
      if [ $e -eq 10 ]; then
        echo "copy: $s: init $dst (chunker params from $src)"
        R init --from-repo "$src" --from-password-file "$pw" --copy-chunker-params || { rc=1; rm -f "$pw"; continue; }
      elif [ $e -ne 0 ]; then
        echo "copy: $s: cannot open $dst (exit $e)" >&2
        rc=1; rm -f "$pw"; continue
      fi

      # The B2 keep set, computed on the LOCAL repo (§2.6): copy only those,
      # so a shallower retentionB2 does not re-copy what B2 pruned.
      p=$(b2Preset "$s")
      # shellcheck disable=SC2046
      want=$(${restic} -r "$src" --password-file "$pw" --no-lock forget --dry-run --json --group-by "" $(presetArgs "$p") </dev/null) || want=""
      ids=$(${jq} -r '[.[] | .keep // [] | .[] | .id] | unique | .[]' <<<"''${want:-null}" 2>/dev/null) || ids=""
      if [ -z "$ids" ]; then
        echo "copy: $s: no B2 keep set from the local repo, copy skipped" >&2
        rc=1
      else
        echo "copy: $s ($(wc -w <<<"$ids") snapshots, preset $p)"
        # shellcheck disable=SC2086
        if R --retry-lock 2h copy --from-repo "$src" --from-password-file "$pw" $ids; then
          stats=$(${jq} -c --arg s "$s" --argjson t "$(date +%s)" '.[$s].lastCopied = $t' <<<"$stats")
        else
          echo "copy: $s: copy failed" >&2
          rc=1
        fi
      fi

      echo "copy: $s: B2 prune ($p)"
      # shellcheck disable=SC2046
      R --retry-lock 2h forget --prune --group-by "" $(presetArgs "$p") || rc=1

      if size=$(R --no-lock stats --mode raw-data --json | ${jq} -e '.total_size'); then
        stats=$(${jq} -c --arg s "$s" --argjson b "$size" '.[$s].b2Bytes = $b' <<<"$stats")
      else
        rc=1
      fi

      # Completeness (§2.6): every snapshot of the keep set above must be in
      # B2, matched on (.original // .id) and the snapshot's content fields.
      # A sampled data read must also pass.
      have=$(R --no-lock snapshots --json) || have=""
      complete=false
      missing='["unknown"]'
      if [ -n "$want" ] && [ -n "$have" ]; then
        missing=$(${jq} -nc --argjson w "$want" --argjson h "$have" '
          def k: {o: (.original // .id), time, hostname, paths, tags, tree};
          [$h[] | k] as $have
          | [$w[] | .keep // [] | .[] | k | select(. as $x | any($have[]; . == $x) | not) | .o]')
        if [ "$missing" != "[]" ]; then
          echo "copy: $s: B2 incomplete, missing $missing" >&2
        elif ! R --no-lock check --read-data-subset ${cfg.checkSubset} >/dev/null; then
          echo "copy: $s: B2 check --read-data-subset ${cfg.checkSubset} failed" >&2
        else
          complete=true
        fi
      else
        echo "copy: $s: B2 completeness unknown (snapshot listing failed)" >&2
      fi
      [ "$complete" = true ] || rc=1
      stats=$(${jq} -c --arg s "$s" --argjson c "$complete" '.[$s].complete = $c' <<<"$stats")
      offsite=$(${jq} -c --arg s "$s" --argjson c "$complete" --argjson m "$missing" --argjson at "$(date +%s)" \
        '.[$s] = {complete: $c, missing: $m, checkedAt: $at}' <<<"$offsite")
      rm -f "$pw"
      # Per subject, so the dashboard sees progress during a long first run.
      writeJson ${b2StatsFile} "$stats"
      writeJson ${offsiteFile} "$offsite"
    done
    writeJson ${b2StatsFile} "$stats"
    writeJson ${offsiteFile} "$offsite"
    exit $rc
  '';

  # Pending `b2` clears: delete every version under <bucket>/svc-<s>/ (B2
  # native API, hard delete), drop the subject's B2 stats, report it in
  # cleared.json. The key cannot reach outside `svc-`.
  clearScript = pkgs.writeShellScript "fleet-backup-pusher-clear" ''
    # Runs after every heartbeat: nothing queued means no key needed.
    ${jq} -e '.clears // {} | any(.[]; . == "b2")' ${policyFile} >/dev/null 2>&1 || exit 0
    ${prologue}
    export RCLONE_B2_ACCOUNT=$AWS_ACCESS_KEY_ID RCLONE_B2_KEY=$AWS_SECRET_ACCESS_KEY RCLONE_B2_HARD_DELETE=true
    export RCLONE_CONFIG=/dev/null
    # Busy copier: leave the clear pending; the next heartbeat retries it.
    exec 9>${lockFile}
    if ! flock -n 9; then
      echo "clear: a copy run holds ${lockFile}; retrying on the next heartbeat"
      exit 0
    fi
    rc=0
    cleared='{}'
    [ -r ${stateDir}/cleared.json ] && cleared=$(cat ${stateDir}/cleared.json)
    stats='{}'
    [ -r ${b2StatsFile} ] && stats=$(cat ${b2StatsFile})
    offsite='{}'
    [ -r ${offsiteFile} ] && offsite=$(cat ${offsiteFile})
    for s in $(${jq} -r '.clears // {} | to_entries[] | select(.value == "b2") | .key' ${policyFile}); do
      validName "$s" || { echo "clear: bad subject '$s'" >&2; rc=1; continue; }
      echo "clear: deleting ${cfg.bucket}/svc-$s/ on B2"
      # Invalidate first: a failed or killed purge must not leave complete:true.
      stats=$(${jq} -c --arg s "$s" 'if .[$s] then .[$s].complete = false else . end' <<<"$stats")
      offsite=$(${jq} -c --arg s "$s" 'if .[$s] then .[$s].complete = false else . end' <<<"$offsite")
      writeJson ${b2StatsFile} "$stats"
      writeJson ${offsiteFile} "$offsite"
      rclone=${pkgs.rclone}/bin/rclone
      # rclone exit 3 = directory not found: nothing (left) under the prefix.
      $rclone purge ":b2:${cfg.bucket}/svc-$s"
      e=$?
      [ $e -eq 0 ] || [ $e -eq 3 ] || { echo "clear: $s: purge failed (exit $e)" >&2; rc=1; continue; }
      left=$($rclone lsf --b2-versions -R ":b2:${cfg.bucket}/svc-$s")
      e=$?
      if { [ $e -eq 0 ] && [ -z "$left" ]; } || [ $e -eq 3 ]; then
        cleared=$(${jq} -c --arg s "$s" '.[$s] = ((.[$s] // []) + ["b2"] | unique)' <<<"$cleared")
        stats=$(${jq} -c --arg s "$s" 'del(.[$s])' <<<"$stats")
        offsite=$(${jq} -c --arg s "$s" 'del(.[$s])' <<<"$offsite")
      else
        echo "clear: $s: objects remain under svc-$s/ (lsf exit $e)" >&2
        rc=1
      fi
    done
    writeJson ${stateDir}/cleared.json "$cleared"
    writeJson ${b2StatsFile} "$stats"
    writeJson ${offsiteFile} "$offsite"
    exit $rc
  '';

  hardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
  };
  mountUnit = {
    RequiresMountsFor = [ target.dataDir ];
    ConditionPathIsMountPoint = target.requiresMount;
  };
in
{
  options.ringofstorms.backup.pusher = {
    enable = lib.mkEnableOption "the backup pusher tier (copies offsite subjects to B2; needs the target tier)";
    endpoint = lib.mkOption {
      type = lib.types.str;
      default = "https://s3.us-west-002.backblazeb2.com";
      description = "B2 S3 endpoint.";
    };
    bucket = lib.mkOption {
      type = lib.types.str;
      example = "belljm-LoiuasdV3-system-backups";
      description = "B2 bucket. Subject repos are <bucket>/svc-<subject>.";
    };
    b2EnvFile = lib.mkOption {
      type = lib.types.str;
      description = "Root-only file with AWS_ACCESS_KEY_ID= and AWS_SECRET_ACCESS_KEY= lines: a B2 app key restricted to the bucket and the `svc-` prefix.";
    };
    maxPolicyAge = lib.mkOption {
      type = lib.types.int;
      default = 1800;
      description = "Seconds. An older policy reply (fleet-edge unreachable) means copy and clear nothing.";
    };
    checkSubset = lib.mkOption {
      type = lib.types.str;
      default = "100M";
      description = "restic check --read-data-subset per B2 repo per run (completeness sample).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = target.enable;
        message = "ringofstorms.backup.pusher needs ringofstorms.backup.target on the same host (it copies the target's repos).";
      }
    ];

    systemd.services.fleet-backup-pusher-copy = {
      description = "Copy offsite backup subjects to B2, prune and verify them";
      after = [
        "network-online.target"
        "fleet-backup-target-prune.service"
      ];
      wants = [ "network-online.target" ];
      unitConfig = mountUnit;
      path = [
        pkgs.coreutils
        pkgs.util-linux
      ];
      serviceConfig = hardening // {
        Type = "oneshot";
        User = "restic";
        Group = "restic";
        ExecStart = copyScript;
        LoadCredential = [
          "repo:${repoKeysDir}"
          "b2env:${cfg.b2EnvFile}"
        ];
        # copy takes a (shared) lock in the source repo.
        ReadWritePaths = [
          target.dataDir
          stateDir
        ];
        CacheDirectory = "fleet-backup-target";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };
    systemd.timers.fleet-backup-pusher-copy = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 07:30:00";
        Persistent = true;
      };
    };

    systemd.services.fleet-backup-pusher-clear = {
      description = "Execute queued B2 backup clears";
      after = [ "fleet-backup-target-clear.service" ];
      path = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.util-linux
      ];
      serviceConfig = hardening // {
        Type = "oneshot";
        User = "restic";
        Group = "restic";
        ExecStart = clearScript;
        LoadCredential = [ "b2env:${cfg.b2EnvFile}" ];
        ReadWritePaths = [ stateDir ];
      };
    };
    systemd.services.fleet-backup-target-heartbeat.onSuccess = [ "fleet-backup-pusher-clear.service" ];
  };
}
