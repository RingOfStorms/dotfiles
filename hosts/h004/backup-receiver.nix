# Receiver for the fleet's rsync-push backups (flakes/common/nix_modules/backup.nix).
# Hosts SSH in as `constants.host.primaryUser` with a dedicated
# backup_to_h004 key whose authorized_keys entry forces
# `fleet-backup-receive`, so that key can do nothing but run the handful of
# exact commands backup.nix issues over SSH, all scoped under
# /data/backups/<host>/...
{
  config,
  lib,
  pkgs,
  constants,
  fleet,
  ...
}:
let
  # Matches a per-host backup dir, optionally with a timestamped snapshot
  # subdir, e.g.:
  #   /data/backups/h001
  #   /data/backups/h001/2026-10-22_030000
  #   /data/backups/h001/2026-10-22_030000/
  pathRe = "^/data/backups/[a-z0-9_-]+(/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}/?)?$";

  backupReceive = pkgs.writeShellApplication {
    name = "fleet-backup-receive";
    runtimeInputs = [
      pkgs.gnugrep
      pkgs.coreutils
      pkgs.rsync
    ];
    text = ''
      set -f
      PATH_RE='${pathRe}'
      cmd="''${SSH_ORIGINAL_COMMAND:-}"

      if [ -z "$cmd" ]; then
        echo "fleet-backup-receive: no command given" >&2
        exit 1
      fi

      # 1) mkdir -p /data/backups/<host>
      if [[ "$cmd" =~ ^mkdir\ -p\ (/data/backups/[a-z0-9_-]+)$ ]]; then
        target="''${BASH_REMATCH[1]}"
        if [[ "$target" =~ $PATH_RE ]]; then
          exec mkdir -p "$target"
        fi
      fi

      # 2) ls -1 /data/backups/<host> | grep -E '^[0-9]{4}-...$' | sort [| tail -1]
      if [[ "$cmd" =~ ^ls\ -1\ (/data/backups/[a-z0-9_-]+)\ \|\ grep\ -E\ \'\^\[0-9\]\{4\}-\[0-9\]\{2\}-\[0-9\]\{2\}_\[0-9\]\{6\}\$\'\ \|\ sort(\ \|\ tail\ -1)?$ ]]; then
        target="''${BASH_REMATCH[1]}"
        tail_part="''${BASH_REMATCH[2]:-}"
        if [[ "$target" =~ $PATH_RE ]]; then
          # shellcheck disable=SC2010
          if [ -n "$tail_part" ]; then
            ls -1 "$target" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' | sort | tail -1
          else
            ls -1 "$target" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' | sort
          fi
          exit 0
        fi
      fi

      # 3) rsync --fake-super --server ... . /data/backups/<host>/<ts>/
      if [[ "$cmd" =~ ^rsync\  ]]; then
        read -r -a argv <<< "$cmd"
        ok=1
        n=''${#argv[@]}
        if [ "''${argv[0]}" != "rsync" ]; then
          ok=0
        fi
        has_server=0
        has_fake_super=0
        has_sender=0
        for a in "''${argv[@]}"; do
          [ "$a" = "--server" ] && has_server=1
          [ "$a" = "--fake-super" ] && has_fake_super=1
          [ "$a" = "--sender" ] && has_sender=1
        done
        if [ "$has_server" -ne 1 ] || [ "$has_fake_super" -ne 1 ] || [ "$has_sender" -eq 1 ]; then
          ok=0
        fi
        if [ "$n" -lt 3 ]; then
          ok=0
        fi
        last="''${argv[$((n-1))]}"
        dot="''${argv[$((n-2))]}"
        if [ "$dot" != "." ]; then
          ok=0
        fi
        if [[ ! "$last" =~ ^/data/backups/([a-z0-9_-]+)/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}/?$ ]]; then
          ok=0
        fi
        dest_host="''${BASH_REMATCH[1]:-}"
        if [ "$ok" -eq 1 ]; then
          for ((i = 1; i < n - 2; i++)); do
            a="''${argv[$i]}"
            case "$a" in
              --server | --fake-super | --numeric-ids | --delete) ;;
              --link-dest=*)
                if [[ ! "$a" =~ ^--link-dest=/data/backups/([a-z0-9_-]+)/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$ ]]; then
                  ok=0
                elif [ "''${BASH_REMATCH[1]}" != "$dest_host" ]; then
                  ok=0
                fi
                ;;
              -[logDtprReiLsfxCIvu.]*)
                if [[ ! "$a" =~ ^-[logDtprReiLsfxCIvu.]+$ ]]; then
                  ok=0
                fi
                ;;
              *)
                ok=0
                ;;
            esac
          done
        fi
        if [ "$ok" -eq 1 ]; then
          exec rsync "''${argv[@]:1}"
        fi
      fi

      # 4) ln -sfn /data/backups/<host>/<ts> /data/backups/<host>/latest
      if [[ "$cmd" =~ ^ln\ -sfn\ (/data/backups/[a-z0-9_-]+/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6})\ (/data/backups/[a-z0-9_-]+/latest)$ ]]; then
        src="''${BASH_REMATCH[1]}"
        dst="''${BASH_REMATCH[2]}"
        if [[ "$src" =~ $PATH_RE ]]; then
          exec ln -sfn "$src" "$dst"
        fi
      fi

      # 5) rm -rf /data/backups/<host>/<snap>
      if [[ "$cmd" =~ ^rm\ -rf\ (/data/backups/[a-z0-9_-]+/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6})$ ]]; then
        target="''${BASH_REMATCH[1]}"
        if [[ "$target" =~ $PATH_RE ]]; then
          exec rm -rf "$target"
        fi
      fi

      echo "fleet-backup-receive: rejected command: $cmd" >&2
      exit 1
    '';
  };
in
{
  options.fleet.backupToH004PubKey = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = fleet.global.backupToH004PubKey or null;
    description = "Dedicated SSH public key for the fleet's rsync-push backups to h004 (flakes/common/nix_modules/backup.nix), restricted to fleet-backup-receive under /data/backups.";
  };

  config = {
    environment.systemPackages = [ backupReceive ];
    users.users.${constants.host.primaryUser}.openssh.authorizedKeys.keys =
      lib.optional (config.fleet.backupToH004PubKey != null)
        ''command="/run/current-system/sw/bin/fleet-backup-receive",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc ${config.fleet.backupToH004PubKey}'';
  };
}
