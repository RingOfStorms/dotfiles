# Backup client tier (containers/BACKUP-PLAN.md §2.1, §2.4, §3).
#
# One repo per subject (svc-<name>) on the target the fleet-edge policy
# names; the per-subject credentials (RESTIC_PASSWORD, RESTIC_REST_USERNAME,
# RESTIC_REST_PASSWORD) come from h005 fleet-edge (`fleet containers
# backup-creds`, only while the subject is placed here or this host is its
# move destination), cached root 0600 in credsDir for when fleet-edge is down
# (§2.7). Subjects are floating services (the containers module fills
# `containers`) and host subjects (`ringofstorms.backup.subjects`).
#
# The repos are append-only: this client NEVER runs forget or prune.
# Retention runs on the target (target.nix fleet-backup-target-prune).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ringofstorms.backup.client;
  subjects = config.ringofstorms.backup.subjects;
  fleetLib = import ../../../containers/lib.nix;
  fleetBin = lib.getExe config.ringofstorms.fleetAgent.package;
  cacheFile = "/var/lib/fleet-backup/target.json";
  credsDir = "/var/lib/fleet-backup/creds";
  cont = cfg.containers;

  # Host-subject validation (§3.3): names never collide with a service,
  # paths pass the same checks as service extraPaths and overlap nothing.
  serviceNames = map (s: s.name) (fleetLib.allServices ../../../containers);
  checkedSubjects = lib.mapAttrs (
    name: s:
    let
      where = "ringofstorms.backup.subjects.${name}";
    in
    if builtins.elem name serviceNames then
      throw "${where}: collides with the floating service ${name}"
    else if builtins.match "[a-z0-9][a-z0-9-]*" name == null then
      throw "${where}: name must match [a-z0-9][a-z0-9-]*"
    else if s.paths == [ ] then
      throw "${where}: paths must not be empty"
    else
      {
        paths = map (fleetLib.checkBackupPath where "path") s.paths;
        exclude = map (fleetLib.checkBackupExclude where) s.exclude;
        hooks = fleetLib.checkBackupHooks where s.hooks;
      }
  ) subjects;
  pathsChecked = fleetLib.checkBackupPaths {
    services = fleetLib.allServices ../../../containers;
    hostSubjects = lib.mapAttrs (_: s: s.paths) checkedSubjects;
  };

  hookFn = fn: pick: set: ''
    ${fn}() {
      case "$1" in
    ${
      lib.concatStrings (
        lib.mapAttrsToList (n: s: lib.optionalString (pick s != null) "    ${n}) ${pick s} ;;\n") set
      )
    }    *) return 0 ;;
      esac
    }
  '';

  # extraPath records: "<subject>\t<path>\t<mount|->\t<sentinel|->"
  extraLines = lib.concatStrings (
    lib.mapAttrsToList (
      n: s:
      lib.concatMapStrings (
        e:
        "${n}\t${e.path}\t${if e.mount == null then "-" else e.mount}\t${
          if e.sentinel == null then "-" else e.sentinel
        }\n"
      ) (s.extraPaths or [ ])
    ) cont.services
  );
  extraFile = pkgs.writeText "fleet-backup-extra-paths" extraLines;
  # Subject-relative excludes: "<subject>\t<absolute pattern>"
  excludeLines = lib.concatStrings (
    (lib.mapAttrsToList (
      n: s:
      lib.concatMapStrings (p: "${n}\t${cont.root}/${n}/${p}\n") (s.exclude or [ ])
      + lib.concatMapStrings (e: lib.concatMapStrings (p: "${n}\t${e.path}/${p}\n") e.exclude) (
        s.extraPaths or [ ]
      )
    ) cont.services)
    ++ lib.mapAttrsToList (
      n: s: lib.concatMapStrings (p: lib.concatMapStrings (x: "${n}\t${p}/${x}\n") s.exclude) s.paths
    ) checkedSubjects
  );
  subjectExcludes = pkgs.writeText "fleet-backup-subject-excludes" excludeLines;
  hostPathLines = lib.concatStrings (
    lib.mapAttrsToList (n: s: lib.concatMapStrings (p: "${n}\t${p}\n") s.paths) checkedSubjects
  );
  hostPaths = pkgs.writeText "fleet-backup-host-paths" hostPathLines;
  globalExcludes = pkgs.writeText "fleet-backup-excludes" (lib.concatLines cont.exclude);

  # `fleet-backup` backs up every subject on this host (installed services
  # and host subjects). `fleet-backup <subject>...` (fleet-backup-svc@, used
  # by `cnt move`) only those, even if their unit is not running. On success
  # each subject gets a stamp in ${cfg.stampDir}/<subject>:
  #   time=<RFC3339 UTC> snapshot=<id> host=<hostname> target=<id> repo=<url>
  backupScript = pkgs.writeShellScript "fleet-backup" ''
    set -u
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.gawk
        pkgs.systemd
        pkgs.sqlite
        pkgs.restic
        pkgs.util-linux
      ]
    }
    stamps=${cfg.stampDir}
    staging=/var/lib/fleet-backup/staging
    host=$(${pkgs.hostname}/bin/hostname)
    install -d -m755 "$stamps"
    install -d -m700 "$staging"
    ${hookFn "containerPre" (s: s.preHook or null) cont.services}
    ${hookFn "containerPost" (s: s.postHook or null) cont.services}
    ${hookFn "hostPre" (s: s.hooks.pre) checkedSubjects}
    ${hookFn "hostPost" (s: s.hooks.post) checkedSubjects}
    isHostSubject() { grep -q "^$1	" ${hostPaths}; }
    isContainer() { ${
      if cont.enable then
        ''case " ${lib.concatStringsSep " " (builtins.attrNames cont.services)} " in *" $1 "*) return 0 ;; esac; return 1''
      else
        "return 1"
    }; }
    unitOf() {
      if [ -e ${cont.mutableDir}/container@$1.service ]; then echo container@$1.service
      elif [ -e ${cont.mutableDir}/fleet-$1.service ]; then echo fleet-$1.service
      fi
    }
    cred() { ${fleetBin} containers backup-creds "$1" --dir ${credsDir} | sed -n 's/^creds=//p'; }
    field() { sed -n "s/^$1=//p" "$2" | tail -n1; }

    # Runtime checks for one extra path (§3.3): local, present, mounted.
    checkExtra() { # path mount sentinel
      local p=$1 m=$2 snt=$3 fs tgt
      [ -e "$p" ] || { echo "$p: missing" >&2; return 1; }
      fs=$(findmnt -no FSTYPE -T "$p") || { echo "$p: findmnt failed" >&2; return 1; }
      case "$fs" in nfs*|cifs|smb3|fuse.sshfs|autofs|9p)
        echo "$p: remote path ($fs): back it up on the host that owns it" >&2; return 1 ;;
      esac
      if [ "$m" != - ]; then
        tgt=$(findmnt -no TARGET -T "$p")
        [ "$tgt" = "$m" ] || { echo "$p: on $tgt, expected mount $m (not mounted?)" >&2; return 1; }
      fi
      if [ "$snt" != - ] && [ ! -f "$snt" ]; then echo "$p: sentinel $snt missing" >&2; return 1; fi
    }

    if [ $# -gt 0 ]; then
      only=1
      list=("$@")
    else
      only=0
      list=()
      ${lib.optionalString cont.enable ''
        for d in ${cont.root}/*/; do
          [ -d "$d" ] || continue
          n=$(basename "$d")
          case "$n" in *.*) continue ;; esac # <svc>.moved-<date> leftovers
          list+=("$n")
        done
      ''}
      for n in ${lib.escapeShellArgs (builtins.attrNames checkedSubjects)}; do list+=("$n"); done
    fi

    failed=""
    for name in "''${list[@]}"; do
      case "$name" in "" | .* | *.* | */*) echo "bad subject name: $name" >&2; exit 2 ;; esac
      kind=""
      if isHostSubject "$name"; then kind=host
      elif isContainer "$name" && [ -d "${cont.root}/$name" ]; then
        unit=$(unitOf "$name")
        if [ -z "$unit" ]; then
          # data left behind without a unit is stale and not backed up
          echo "$name: not installed on $host, skipped" >&2
          [ "$only" = 0 ] || failed="$failed $name"
          continue
        fi
        kind=container
      else
        echo "$name: not a backup subject on $host" >&2
        failed="$failed $name"
        continue
      fi
      echo "== $name ($kind)" >&2
      (
        set -eu -o pipefail
        # One run per subject at a time (nightly vs `cnt move`).
        exec 9>"$staging/$name.lock"
        flock 9

        # Resolve once per run: policy from fleet-edge, cache fallback, no guess.
        res=$(${fleetBin} containers backup-resolve "$name" --cache ${cacheFile}) || {
          echo "$name: cannot resolve a backup target" >&2; exit 1; }
        target=$(sed -n 's/^target=//p' <<<"$res")
        repo=$(sed -n 's/^repo=//p' <<<"$res")
        if [ "$target" = none ]; then
          echo "$name: backups turned off in the policy (target=none), skipped" >&2
          exit 0
        fi
        case "$repo" in rest:http://*/svc-"$name"/ | rest:https://*/svc-"$name"/) ;;
          *) echo "$name: resolver gave a bad repo '$repo'" >&2; exit 1 ;; esac

        c=$(cred "$name")
        [ -n "$c" ] && [ -s "$c" ] || { echo "$name: no backup credentials for $host from h005 (not placed here?)" >&2; exit 1; }
        RESTIC_PASSWORD=$(field RESTIC_PASSWORD "$c")
        RESTIC_REST_USERNAME=$(field RESTIC_REST_USERNAME "$c")
        RESTIC_REST_PASSWORD=$(field RESTIC_REST_PASSWORD "$c")
        [ "$RESTIC_REST_USERNAME" = "svc-$name" ] && [ -n "$RESTIC_PASSWORD" ] && [ -n "$RESTIC_REST_PASSWORD" ] || {
          echo "$name: credential $c is malformed (RESTIC_REST_USERNAME must be svc-$name)" >&2; exit 1; }
        export RESTIC_PASSWORD RESTIC_REST_USERNAME RESTIC_REST_PASSWORD
        export RESTIC_REPOSITORY="$repo"

        ex=$staging/$name.excludes
        : > "$ex"
        awk -F'\t' -v s="$name" '$1 == s { print $2 }' ${subjectExcludes} >> "$ex"
        paths=()
        ran_pre=0
        if [ "$kind" = container ]; then
          dir=${cont.root}/$name
          paths+=("$dir")
          if [ "$(systemctl is-active "$unit" || true)" = active ]; then
            ran_pre=1
            containerPre "$name" || exit 1
          else
            echo "$name: not running, hook skipped (data is at rest)" >&2
          fi
          # Consistent SQLite copies via the online backup API (host side,
          # any container kind); the live db/-wal/-shm files are excluded.
          st=$staging/$name
          rm -rf "$st"
          install -d -m700 "$st/sqlite"
          find "$dir" -xdev -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) \
            -not -path '*/postgres/*' -not -path '*/postgresql/*' -print0 |
          while IFS= read -r -d "" db; do
            [ "$(head -c 15 "$db")" = "SQLite format 3" ] || continue
            out="$st/sqlite''${db#${cont.root}}"
            install -d -m700 "$(dirname "$out")"
            sqlite3 "$db" ".timeout 30000" ".backup '$out'" || exit 1
            # the copy replaces the live file on restore: keep owner and mode
            chown --reference="$db" "$out"
            chmod --reference="$db" "$out"
            printf '%s\n' "$db" "$db-wal" "$db-shm" "$db-journal" >> "$ex"
            # opening an idle WAL db creates -wal/-shm; keep the app's owner
            for f in "$db-wal" "$db-shm"; do [ ! -e "$f" ] || chown --reference="$db" "$f"; done
          done
          paths+=("$st")
          while IFS=$'\t' read -r s p m snt; do
            [ "$s" = "$name" ] || continue
            checkExtra "$p" "$m" "$snt" || exit 1
            paths+=("$p")
          done < ${extraFile}
        else
          ran_pre=1
          hostPre "$name" || exit 1
          while IFS=$'\t' read -r s p; do
            [ "$s" = "$name" ] || continue
            [ -e "$p" ] || { echo "$name: $p missing" >&2; exit 1; }
            paths+=("$p")
          done < ${hostPaths}
        fi

        gx=()
        if [ "$kind" = container ]; then gx=(--exclude-file=${globalExcludes}); fi
        rc=0
        snap=$(restic backup --json --retry-lock 2h --host "$host" --tag fleet --tag "svc:$name" \
          --group-by tags --exclude-caches --exclude-file="$ex" \
          "''${gx[@]}" "''${paths[@]}" </dev/null |
          grep -o '"snapshot_id":"[0-9a-f]*"' | tail -n1 | cut -d'"' -f4) || rc=1
        if [ "$ran_pre" = 1 ]; then
          if [ "$kind" = container ]; then containerPost "$name" || rc=1; else hostPost "$name" || rc=1; fi
        fi
        [ "$rc" = 0 ] || exit 1
        [ -n "$snap" ] || { echo "$name: restic printed no snapshot id" >&2; exit 1; }
        printf 'time=%s snapshot=%s host=%s target=%s repo=%s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$snap" "$host" "$target" "$repo" > "$stamps/.$name.new"
        chmod 644 "$stamps/.$name.new"
        mv -f "$stamps/.$name.new" "$stamps/$name"
        echo "$name: snapshot $snap in $repo" >&2
      ) || { echo "$name: BACKUP FAILED" >&2; failed="$failed $name"; }
    done
    if [ -n "$failed" ]; then echo "failed:$failed" >&2; exit 1; fi
  '';

  # restic with one subject's credentials (root only):
  #   fleet-restic --subject <name> [-r <repo>] <restic args>
  # Without -r the subject's repo is resolved (policy, then cache).
  fleetRestic = pkgs.writeShellScriptBin "fleet-restic" ''
    set -euo pipefail
    subject="" repo=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --subject) subject=$2; shift 2 ;;
        --subject=*) subject=''${1#--subject=}; shift ;;
        -r|--repo) repo=$2; shift 2 ;;
        --repo=*) repo=''${1#--repo=}; shift ;;
        *) break ;;
      esac
    done
    [ -n "$subject" ] || { echo "usage: fleet-restic --subject <name> [-r <repo>] <restic args>" >&2; exit 2; }
    c=$(${fleetBin} containers backup-creds "$subject" --dir ${credsDir} | ${pkgs.gnused}/bin/sed -n 's/^creds=//p')
    [ -n "$c" ] && [ -s "$c" ] || { echo "fleet-restic: no backup credentials for $subject on this host" >&2; exit 1; }
    field() { ${pkgs.gnused}/bin/sed -n "s/^$1=//p" "$c" | ${pkgs.coreutils}/bin/tail -n1; }
    if [ -z "$repo" ]; then
      res=$(${fleetBin} containers backup-resolve "$subject" --cache ${cacheFile})
      repo=$(${pkgs.gnused}/bin/sed -n 's/^repo=//p' <<<"$res")
      [ -n "$repo" ] || { echo "fleet-restic: $subject has no backup target (target=none)" >&2; exit 1; }
    fi
    case "$repo" in rest:http://*|rest:https://*) ;; *) echo "fleet-restic: repo must be rest:http(s)://…" >&2; exit 2 ;; esac
    RESTIC_PASSWORD=$(field RESTIC_PASSWORD)
    RESTIC_REST_USERNAME=$(field RESTIC_REST_USERNAME)
    RESTIC_REST_PASSWORD=$(field RESTIC_REST_PASSWORD)
    export RESTIC_PASSWORD RESTIC_REST_USERNAME RESTIC_REST_PASSWORD
    unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
    export RESTIC_CACHE_DIR=/var/cache/fleet-backup
    exec ${pkgs.restic}/bin/restic -r "$repo" "$@"
  '';

  backupUnit = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig = lib.optionalAttrs cont.enable { RequiresMountsFor = [ cont.root ]; };
    environment.RESTIC_CACHE_DIR = "/var/cache/fleet-backup";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "fleet-backup";
      StateDirectoryMode = "0700";
      CacheDirectory = "fleet-backup";
      CacheDirectoryMode = "0700";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };
in
{
  options.ringofstorms.backup = {
    client = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = subjects != { };
        defaultText = lib.literalExpression "ringofstorms.backup.subjects != { }";
        description = "Nightly per-subject restic backup to the policy's target (fleet-backup.service).";
      };
      schedule = lib.mkOption {
        type = lib.types.str;
        default = "03:00";
        description = "systemd OnCalendar (up to 15 min random delay, Persistent).";
      };
      stampDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/fleet-backup/backup-last";
        description = "Success stamps, one file per subject. The containers module sets /var/lib/fleet-containers/backup-last.";
      };
      containers = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          internal = true;
        };
        root = lib.mkOption {
          type = lib.types.str;
          default = "/srv/containers";
          internal = true;
        };
        mutableDir = lib.mkOption {
          type = lib.types.str;
          default = "/etc/systemd-mutable/system";
          internal = true;
        };
        exclude = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          internal = true;
          description = "Host-wide restic exclude patterns for container subjects.";
        };
        services = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          internal = true;
          description = "name -> { preHook; postHook; exclude; extraPaths; } (host shell commands; set by the containers module).";
        };
      };
    };
    subjects = lib.mkOption {
      default = { };
      description = "Host subjects (BACKUP-PLAN.md §3.2): non-container data backed up as repo svc-<name>.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            paths = lib.mkOption { type = lib.types.listOf lib.types.str; };
            exclude = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            hooks = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "pre/post: host shell, as root.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cont.enable || subjects != { };
        message = "ringofstorms.backup.client needs a subject source: the containers module or ringofstorms.backup.subjects.";
      }
      {
        assertion = builtins.deepSeq checkedSubjects (builtins.isList pathsChecked);
        message = "ringofstorms.backup.subjects failed validation.";
      }
    ];
    environment.systemPackages = [ fleetRestic ];
    systemd.services.fleet-backup = backupUnit // {
      description = "restic backup of every backup subject on this host";
      serviceConfig = backupUnit.serviceConfig // {
        ExecStart = backupScript;
      };
    };
    # One subject now (`cnt move`): systemctl start fleet-backup-svc@puzzles
    systemd.services."fleet-backup-svc@" = backupUnit // {
      description = "restic backup of backup subject %i";
      serviceConfig = backupUnit.serviceConfig // {
        ExecStart = "${backupScript} %i";
      };
    };
    systemd.timers.fleet-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "15m";
      };
    };
  };
}
