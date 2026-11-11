# Backup target tier (containers/BACKUP-PLAN.md §2.1, §2.5, §2.8, §4.3).
#
# rest-server on :8000 (socket activated), append-only, privateRepos, htpasswd
# rendered into /run from fleet-edge's REST-login feed (heartbeat), a per-repo prune
# run as `restic`, and the tailnet firewall rule. No B2 key here (pusher tier).
{
  config,
  lib,
  pkgs,
  fleet ? { },
  ...
}:
let
  cfg = config.ringofstorms.backup.target;
  pusher = config.ringofstorms.backup.pusher;
  hosts = fleet.hosts or { };
  self = config.networking.hostName;
  fleetLib = import ../../../containers/lib.nix;
  allow = fleetLib.backupTargetIps {
    inherit hosts self;
    inherit (cfg) lowTrustClients;
  };
  port = 8000;
  htDir = "/run/restic-rest-server";
  htFile = "${htDir}/htpasswd";
  mountUnit = {
    RequiresMountsFor = cfg.requiresMount;
    ConditionPathIsMountPoint = cfg.requiresMount;
  };

  presets = {
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
  };

  # Root oneshot: one `user:$2y$…` line per subject login from fleet-edge's
  # heartbeat feed (credsFeed, root 0600; never holds repo passwords), atomic
  # rename, then applied.json {subject: restRevision} for the next heartbeat.
  # No feed yet: an empty htpasswd (nobody logs in).
  renderScript = pkgs.writeShellScript "render-htpasswd" ''
    set -euo pipefail
    umask 0077
    install -d -m 0750 -o root -g restic ${htDir}
    tmp=$(mktemp ${htDir}/.htpasswd.XXXXXX)
    trap 'rm -f "$tmp"' EXIT
    applied='{}'
    if [ -s ${credsFeed} ]; then
      while IFS=$'\t' read -r s u p rev; do
        case "$s" in ""|*[!a-z0-9-]*) echo "render-htpasswd: bad subject '$s'" >&2; exit 1 ;; esac
        if [ "$u" != "svc-$s" ] || [ -z "$p" ]; then
          echo "render-htpasswd: $s: username must be svc-$s and the password non-empty" >&2
          exit 1
        fi
        line=$(printf '%s' "$p" | ${pkgs.apacheHttpd}/bin/htpasswd -niB "$u")
        case "$line" in
          "$u:\$2y\$"*) printf '%s\n' "$line" >>"$tmp" ;;
          *) echo "render-htpasswd: unexpected htpasswd output for $u" >&2; exit 1 ;;
        esac
        applied=$(${jq} -c --arg s "$s" --argjson r "$rev" '.[$s] = $r' <<<"$applied")
      done < <(${jq} -r 'to_entries[] | [.key, .value.username, .value.restPassword, (.value.restRevision|tostring)] | @tsv' ${credsFeed})
    fi
    chgrp restic "$tmp"
    chmod 0640 "$tmp"
    mv -f "$tmp" ${htFile}
    trap - EXIT
    a=$(mktemp ${keyState}/.applied.XXXXXX)
    printf '%s\n' "$applied" >"$a"
    mv -f "$a" ${appliedFile}
  '';

  stateDir = "/var/lib/fleet-backup-target";
  # Root-only: REST logins (htpasswd input) and, separately, the repo
  # passwords of held repos (prune/stats via LoadCredential). Never readable
  # by `restic` directly.
  keyState = "/var/lib/fleet-backup-target-keys";
  credsFeed = "${keyState}/rest-logins.json";
  appliedFile = "${keyState}/applied.json";
  repoKeysDir = "${keyState}/repo-keys";
  policyFile = "${stateDir}/policy.json";
  jq = "${pkgs.jq}/bin/jq";
  repoUrl = "rest:http://${hosts.${self}.overlayIp or ""}:${toString port}/";

  # Root (the machine key is root-only): register, post stats and finished
  # clears, save the reply (presets per repo, pending clears) for the
  # restic-run units below. fleet-edge unreachable: the old reply stays.
  heartbeatScript = pkgs.writeShellScript "fleet-backup-target-heartbeat" ''
    set -euo pipefail
    stats=${stateDir}/stats.json
    ${lib.optionalString pusher.enable ''
      # Pusher tier: its B2 fields (b2-stats.json) merged per subject.
      if [ -r ${stateDir}/b2-stats.json ]; then
        stats=$(mktemp)
        trap 'rm -f "$stats"' EXIT
        cat ${stateDir}/stats.json ${stateDir}/b2-stats.json 2>/dev/null \
          | ${jq} -s 'reduce .[] as $x ({}; . * $x)' >"$stats"
      fi
    ''}
    ${lib.getExe config.ringofstorms.fleetAgent.package} containers backup-policy heartbeat \
      --id ${lib.escapeShellArg self} --url ${lib.escapeShellArg repoUrl} \
      --stats "$stats" --out ${policyFile} ${lib.optionalString pusher.enable "--pusher"} \
      --creds-out ${credsFeed}.new --applied ${appliedFile}
    chown restic:restic ${policyFile}
    # New REST logins (rotation, new subject): re-render and SIGHUP rest-server.
    if [ -s ${credsFeed}.new ] && ! ${pkgs.diffutils}/bin/cmp -s ${credsFeed}.new ${credsFeed}; then
      mv -f ${credsFeed}.new ${credsFeed}
      systemctl reload-or-restart render-htpasswd.service
    else
      rm -f ${credsFeed}.new
    fi
    # Repo passwords of the repos this target holds (§2.7), for prune/stats.
    ${lib.getExe config.ringofstorms.fleetAgent.package} containers backup-policy repo-keys \
      --id ${lib.escapeShellArg self} --dir ${repoKeysDir} >/dev/null
  '';

  # preset NAME: the policy's preset for subject NAME, else cfg.prunePreset
  # (no policy reply yet: `long` by default, the safe direction).
  presetFns = ''
    preset() {
      local p=""
      [ -r ${policyFile} ] && p=$(${jq} -r --arg s "$1" '.retention[$s] // empty' ${policyFile} 2>/dev/null || true)
      case "$p" in short|standard|long) echo "$p" ;; *) echo ${cfg.prunePreset} ;; esac
    }
    presetArgs() {
      case "$1" in
      ${lib.concatStrings (
        lib.mapAttrsToList (n: a: "  ${n}) echo ${lib.escapeShellArgs a} ;;\n") presets
      )}
      esac
    }
  '';

  # Runs as `restic`, hourly: raw size and newest snapshot per repo, as
  # {subject: {localBytes, lastBackup, at}} (0600). A repo whose stats fail
  # gets no entry, never a 0.
  statsScript = pkgs.writeShellScript "fleet-backup-target-stats" ''
    set -uo pipefail
    export RESTIC_CACHE_DIR=/var/cache/fleet-backup-target
    umask 0077
    out='{}'
    now=$(${pkgs.coreutils}/bin/date +%s)
    shopt -s nullglob
    for repo in ${cfg.dataDir}/svc-*/; do
      repo=''${repo%/}
      name=''${repo##*/}
      cred="''${CREDENTIALS_DIRECTORY:-/nonexistent}/repo_$name"
      [ -r "$cred" ] || continue
      pw=$(mktemp)
      ${pkgs.gnused}/bin/sed -n 's/^RESTIC_PASSWORD=//p' "$cred" | ${pkgs.coreutils}/bin/tail -n1 >"$pw"
      if size=$(${pkgs.restic}/bin/restic -r "$repo" --password-file "$pw" --no-lock stats --mode raw-data --json </dev/null | ${jq} -e '.total_size'); then
        last=$(${pkgs.restic}/bin/restic -r "$repo" --password-file "$pw" --no-lock snapshots --latest 1 --json </dev/null | ${jq} -r '[.[].time] | max // empty' || true)
        lastTs=0
        [ -n "$last" ] && lastTs=$(${pkgs.coreutils}/bin/date -d "$last" +%s)
        out=$(${jq} -c --arg s "''${name#svc-}" --argjson b "$size" --argjson l "$lastTs" --argjson at "$now" \
          '.[$s] = {localBytes: $b, lastBackup: $l, at: $at}' <<<"$out")
      else
        echo "stats: $name failed" >&2
      fi
      rm -f "$pw"
    done
    tmp=$(mktemp ${stateDir}/.stats.XXXXXX)
    printf '%s\n' "$out" >"$tmp"
    mv -f "$tmp" ${stateDir}/stats.json
  '';

  # Runs as `restic` after each heartbeat: executes pending `local` clears
  # (deletes <dataDir>/svc-<subject>) and records them in cleared.json,
  # reported by the next heartbeat. A subject whose policy target is still
  # this host (reply `.local`) gets an empty repo again with its existing
  # password, so its client's next backup works; a turned-off subject is
  # left without a repo. `b2` clears belong to the pusher tier.
  clearScript = pkgs.writeShellScript "fleet-backup-target-clear" ''
    set -euo pipefail
    umask 0077
    export RESTIC_CACHE_DIR=/var/cache/fleet-backup-target
    [ -r ${policyFile} ] || exit 0
    ${lib.optionalString pusher.enable ''
      # Pusher host: the copier reads <dataDir>/svc-* as its source. Share its
      # lock; a busy copier leaves local clears pending for the next heartbeat.
      exec 9>${stateDir}/pusher.lock
      if ! ${pkgs.util-linux}/bin/flock -n 9; then
        echo "clear: a B2 copy run holds the pusher lock; retrying on the next heartbeat"
        exit 0
      fi
    ''}
    cleared='{}'
    [ -r ${stateDir}/cleared.json ] && cleared=$(cat ${stateDir}/cleared.json)
    rc=0
    for s in $(${jq} -r '.clears // {} | to_entries[] | select(.value == "local") | .key' ${policyFile}); do
      case "$s" in ""|*[!a-z0-9-]*) echo "clear: bad subject $s" >&2; continue ;; esac
      repo=${cfg.dataDir}/svc-$s
      echo "clear: deleting $repo"
      rm -rf --one-file-system -- "$repo"
      cleared=$(${jq} -c --arg s "$s" '.[$s] = ((.[$s] // []) + ["local"] | unique)' <<<"$cleared")
      if ${jq} -e --arg s "$s" '(.local // []) | index($s) != null' ${policyFile} >/dev/null; then
        cred="''${CREDENTIALS_DIRECTORY:-/nonexistent}/repo_svc-$s"
        pw=$(mktemp)
        ${pkgs.gnused}/bin/sed -n 's/^RESTIC_PASSWORD=//p' "$cred" 2>/dev/null | ${pkgs.coreutils}/bin/tail -n1 >"$pw" || true
        if [ -s "$pw" ] && ${pkgs.restic}/bin/restic init -r "$repo" --password-file "$pw" </dev/null >/dev/null; then
          echo "clear: $s: re-created an empty $repo (target is still this host)"
        else
          echo "clear: $s: re-creating $repo failed; its backups fail until restic init is run as restic" >&2
          rc=1
        fi
        rm -f "$pw"
      fi
    done
    tmp=$(mktemp ${stateDir}/.cleared.XXXXXX)
    printf '%s\n' "$cleared" >"$tmp"
    mv -f "$tmp" ${stateDir}/cleared.json
    exit $rc
  '';

  # Runs as `restic`. Repo passwords arrive via LoadCredential (repo_svc-<s>,
  # from the heartbeat's repo-keys fetch).
  # Presets come from the policy reply (heartbeat), else cfg.prunePreset.
  pruneScript = pkgs.writeShellScript "fleet-backup-target-prune" ''
    set -uo pipefail
    export RESTIC_CACHE_DIR=/var/cache/fleet-backup-target
    rc=0
    ${presetFns}
    shopt -s nullglob
    for repo in ${cfg.dataDir}/svc-*/; do
      repo=''${repo%/}
      name=''${repo##*/}
      cred="''${CREDENTIALS_DIRECTORY:-/nonexistent}/repo_$name"
      if [ ! -r "$cred" ]; then
        echo "prune: $name: no credential on this target, skipped" >&2
        rc=1
        continue
      fi
      pw=$(mktemp)
      ${pkgs.gnused}/bin/sed -n 's/^RESTIC_PASSWORD=//p' "$cred" | ${pkgs.coreutils}/bin/tail -n1 >"$pw"
      p=$(preset "''${name#svc-}")
      echo "prune: $name ($p)"
      # shellcheck disable=SC2046
      ${pkgs.restic}/bin/restic -r "$repo" --password-file "$pw" --retry-lock 2h \
        forget --prune --group-by "" $(presetArgs "$p") </dev/null || rc=1
      rm -f "$pw"
    done
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
in
{
  options.ringofstorms.backup.target = {
    enable = lib.mkEnableOption "the backup target tier (rest-server receiving restic pushes)";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/data/backups";
      description = "restic target root. Repos are <dataDir>/svc-<subject>.";
    };
    requiresMount = lib.mkOption {
      type = lib.types.str;
      default = "/data";
      description = "Mountpoint dataDir lives on. Every target unit has RequiresMountsFor and ConditionPathIsMountPoint on it.";
    };
    lowTrustClients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "joe" ];
      description = "Low-trust hosts also admitted to :${toString port} (§7).";
    };
    prunePreset = lib.mkOption {
      type = lib.types.enum [
        "short"
        "standard"
        "long"
      ];
      default = "long";
      description = "Retention preset used until the fleet-edge policy exists (P2). `long` is the safe direction.";
    };
    allowedIps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = allow.ips;
      description = "Generated :${toString port} IPv4 allow-list (read-only, for tests).";
    };
    allowedIps6 = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = allow.ips6;
      description = "Generated :${toString port} IPv6 allow-list (read-only, for tests).";
    };
    owner = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "restic";
      description = "Owner (user and group) of dataDir. Consumed by the host's subvolume unit (hosts/h004/nfs-data.nix).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (hosts.${self}.trust or null) == "high";
        message = "ringofstorms.backup.target: ${self} must be trust = \"high\" in hosts/fleet.nix (a target root reads every repo's password).";
      }
      {
        assertion = lib.hasPrefix "${cfg.requiresMount}/" cfg.dataDir;
        message = "ringofstorms.backup.target.dataDir (${cfg.dataDir}) must be under requiresMount (${cfg.requiresMount}).";
      }
      {
        assertion =
          allow.ips != [ ]
          && builtins.elem (hosts.lio.overlayIp or null) allow.ips
          && !(builtins.elem (hosts.${self}.overlayIp or null) allow.ips)
          && !(builtins.elem (hosts.o002.overlayIp or null) allow.ips);
        message = "ringofstorms.backup.target: :${toString port} allow-list must be non-empty, contain lio and exclude o002 and ${self}: ${builtins.toJSON allow}";
      }
      {
        assertion = builtins.all (n: (hosts.${n}.trust or null) == "low") cfg.lowTrustClients;
        message = "ringofstorms.backup.target.lowTrustClients must name trust = \"low\" hosts only (high trust is already admitted).";
      }
      {
        assertion = config.users.users.restic.uid == 291 && config.users.groups.restic.gid == 291;
        message = "ringofstorms.backup.target: restic must keep the fixed uid/gid 291 (impermanent root).";
      }
    ];

    services.restic.server = {
      enable = true;
      listenAddress = toString port;
      inherit (cfg) dataDir;
      appendOnly = true;
      privateRepos = true;
      htpasswd-file = htFile;
    };

    # dataDir is owned by the host's subvolume unit, not user activation (§4.3).
    users.users.restic.createHome = lib.mkForce false;

    systemd.services.render-htpasswd = {
      description = "Render rest-server htpasswd from fleet-edge's backup REST logins";
      before = [ "restic-rest-server.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = renderScript;
        ExecReload = renderScript;
      };
    };

    systemd.services.restic-rest-server = {
      requires = [ "render-htpasswd.service" ];
      after = [ "render-htpasswd.service" ];
      unitConfig = mountUnit // {
        ReloadPropagatedFrom = [ "render-htpasswd.service" ];
      };
      serviceConfig.ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
    };
    systemd.sockets.restic-rest-server.unitConfig = mountUnit;

    systemd.services.fleet-backup-target-prune = {
      description = "restic forget --prune per repo on this backup target";
      after = [ "restic-rest-server.service" ];
      unitConfig = mountUnit;
      serviceConfig = hardening // {
        Type = "oneshot";
        User = "restic";
        Group = "restic";
        ExecStart = pruneScript;
        LoadCredential = [ "repo:${repoKeysDir}" ];
        ReadWritePaths = [ cfg.dataDir ];
        ReadOnlyPaths = [ stateDir ];
        CacheDirectory = "fleet-backup-target";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0700 restic restic -"
      "d ${keyState} 0700 root root -"
      "d ${repoKeysDir} 0700 root root -"
    ];

    systemd.services.fleet-backup-target-heartbeat = {
      description = "Register this backup target with fleet-edge and fetch its policy";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      onSuccess = [ "fleet-backup-target-clear.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = heartbeatScript;
      };
    };
    systemd.timers.fleet-backup-target-heartbeat = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "5m";
        RandomizedDelaySec = "30s";
      };
    };

    systemd.services.fleet-backup-target-stats = {
      description = "restic raw-data size and newest snapshot per repo";
      after = [ "restic-rest-server.service" ];
      unitConfig = mountUnit;
      serviceConfig = hardening // {
        Type = "oneshot";
        User = "restic";
        Group = "restic";
        ExecStart = statsScript;
        LoadCredential = [ "repo:${repoKeysDir}" ];
        ReadOnlyPaths = [ cfg.dataDir ];
        ReadWritePaths = [ stateDir ];
        CacheDirectory = "fleet-backup-target";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };
    systemd.timers.fleet-backup-target-stats = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = "1h";
      };
    };

    systemd.services.fleet-backup-target-clear = {
      description = "Execute queued local backup clears";
      unitConfig = mountUnit;
      serviceConfig = hardening // {
        Type = "oneshot";
        User = "restic";
        Group = "restic";
        ExecStart = clearScript;
        LoadCredential = [ "repo:${repoKeysDir}" ];
        CacheDirectory = "fleet-backup-target";
        ReadWritePaths = [
          cfg.dataDir
          stateDir
        ];
      };
    };
    systemd.timers.fleet-backup-target-prune = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 06:00:00";
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };

    networking.firewall.extraInputRules = ''
      iifname "tailscale0" ip saddr { ${lib.concatStringsSep ", " allow.ips} } tcp dport ${toString port} accept comment "generated: restic rest-server, backup clients only"
      ${lib.optionalString (allow.ips6 != [ ])
        ''iifname "tailscale0" ip6 saddr { ${lib.concatStringsSep ", " allow.ips6} } tcp dport ${toString port} accept comment "generated: restic rest-server, backup clients only (v6)"''
      }
    '';
  };
}
