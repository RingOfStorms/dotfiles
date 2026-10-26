# Receiver for the public wildcard pushed by h005 (hosts/h005/wildcard-cert.nix,
# ROUTING-PLAN §8 step 4). h005 runs `fleet-cert-receive [name]` over root SSH
# with a tar of fullchain.pem + key.pem on stdin. `name` (optional, taken from
# $SSH_ORIGINAL_COMMAND since the forced command strips argv) selects which
# cert this pair is: the zone domain by default, or one of
# `fleet.wildcardExtraCertNames` (e.g. `share.<domain>`, FLOWS-AUDIT.md §c).
# Each name gets its own independent directory/current symlink.
#
# Layout (one directory per pushed pair, swapped by one symlink rename):
#   /var/lib/fleet-cert/<name>/v-<utc time>-<serial>/{fullchain,key}.pem
#   /var/lib/fleet-cert/<name>/current -> v-...
# Sites only name current/fullchain.pem and current/key.pem, so they always see
# both files from the same version. The receiver switches `current`, runs
# `nginx -t` and reloads. If either fails it points `current` back at the
# previous version and exits non-zero, which fails h005's push. It keeps the
# last 3 versions.
#
# Importing this does not change nginx. A host opts in per vhost with
# `fleet.wildcardTls` / `fleet.wildcardCertDir` (main domain) once `current`
# exists: nginx refuses to start on a missing certificate file. The
# activation script below migrates the pre-versioning flat files for the
# main domain into a version dir, so `current` exists before the switched
# sites are reloaded.
{
  config,
  lib,
  pkgs,
  fleet,
  ...
}:
let
  domain = fleet.global.domain;
  certNames = [ domain ] ++ config.fleet.wildcardExtraCertNames;
  dirFor = name: "/var/lib/fleet-cert/${name}";
  dir = dirFor domain;
  current = "${dir}/current";
  nginxCfg = config.services.nginx;
  # The config path differs per host (o002 has no /etc/nginx/nginx.conf):
  # test exactly what the running unit was started with.
  nginxTest = ''"${nginxCfg.package}/bin/nginx" -t -c "$(systemctl show -p ExecStart --value nginx | grep -o -- '-c [^ ;]*' | head -1 | cut -d' ' -f2)"'';

  # Point <dirFor name>/current at $2 (a v-* name) atomically.
  swap = ''
    swap() {
      ln -sfn "$2" "/var/lib/fleet-cert/$1/.current.tmp"
      mv -T "/var/lib/fleet-cert/$1/.current.tmp" "/var/lib/fleet-cert/$1/current"
    }
  '';

  receive = pkgs.writeShellApplication {
    name = "fleet-cert-receive";
    runtimeInputs = [
      pkgs.gnutar
      pkgs.coreutils
      pkgs.openssl
      pkgs.systemd
    ];
    text = ''
      ${swap}
      umask 077
      # The forced command strips argv; the client's requested name (if any)
      # survives in $SSH_ORIGINAL_COMMAND as the *whole* original command
      # line (sshd does not strip the program name, only argv on our side),
      # e.g. "fleet-cert-receive joshuabell.xyz". Strip that prefix to get
      # just the name; falls back to the main domain for pre-multi-cert
      # pushes (bare "fleet-cert-receive", no argument).
      name=''${SSH_ORIGINAL_COMMAND#fleet-cert-receive}
      name=''${name# }
      name=''${name:-${domain}}
      # shellcheck disable=SC2194 # certNames is Nix-interpolated, not a shell var
      case " ${lib.concatStringsSep " " certNames} " in
        *" $name "*) ;;
        *) echo "fleet-cert: unknown cert name: $name" >&2; exit 1 ;;
      esac
      d="/var/lib/fleet-cert/$name"
      cur="$d/current"
      install -d -m 0750 -o root -g nginx "$d"
      tmp=$(mktemp -d "$d/.in.XXXXXX")
      trap 'rm -rf "$tmp"' EXIT
      tar -C "$tmp" -xf - fullchain.pem key.pem
      # Refuse garbage and mismatched pairs before touching anything live.
      openssl x509 -in "$tmp/fullchain.pem" -noout -checkend 86400
      [ "$(openssl x509 -in "$tmp/fullchain.pem" -noout -pubkey | sha256sum)" = \
        "$(openssl pkey -in "$tmp/key.pem" -pubout | sha256sum)" ]
      serial=$(openssl x509 -in "$tmp/fullchain.pem" -noout -serial | cut -d= -f2)

      prev=$(readlink "$cur" || true)
      if [ -n "$prev" ] && cmp -s "$tmp/fullchain.pem" "$d/$prev/fullchain.pem" \
        && cmp -s "$tmp/key.pem" "$d/$prev/key.pem"; then
        echo "fleet-cert: unchanged ($name: $prev)"
        exit 0
      fi

      chown root:nginx "$tmp" "$tmp/fullchain.pem" "$tmp/key.pem"
      chmod 0750 "$tmp"
      chmod 0644 "$tmp/fullchain.pem"
      chmod 0640 "$tmp/key.pem"
      new="v-$(date -u +%Y%m%dT%H%M%S)-$serial"
      mv -T "$tmp" "$d/$new"
      trap - EXIT

      swap "$name" "$new"
      if systemctl is-active --quiet nginx; then
        if ! ${nginxTest} || ! systemctl reload nginx; then
          echo "fleet-cert: nginx rejected $name/$new, rolling back to ''${prev:-nothing}" >&2
          if [ -n "$prev" ]; then
            swap "$name" "$prev"
            systemctl reload nginx || true
          else
            rm -f "$cur"
          fi
          # shellcheck disable=SC2115 # $d and $new are always set (install -d / mktemp above)
          rm -rf "$d/$new"
          exit 1
        fi
      fi

      # Keep the last 3 versions (names sort by time); never the live one.
      find "$d" -mindepth 1 -maxdepth 1 -type d -name 'v-*' -printf '%f\n' \
        | sort -r | tail -n +4 | while read -r old; do
          # shellcheck disable=SC2115 # $d and $old are always set (find glob above)
          [ "$old" = "$new" ] || rm -rf "$d/$old"
        done
      echo "fleet-cert: $name current -> $new ($(openssl x509 -in "$cur/fullchain.pem" -noout -enddate))"
    '';
  };
in
{
  options.fleet.wildcardCertDir = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = current;
    description = "Directory with the pushed wildcard's fullchain.pem and key.pem.";
  };
  options.fleet.wildcardTls = lib.mkOption {
    type = lib.types.attrs;
    readOnly = true;
    description = "nginx vhost TLS attrs that use the pushed wildcard.";
    default = {
      forceSSL = true;
      sslCertificate = "${current}/fullchain.pem";
      sslCertificateKey = "${current}/key.pem";
    };
  };
  options.fleet.wildcardExtraCertNames = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      Extra cert names (besides the main domain) this receiver accepts from
      h005, each getting its own /var/lib/fleet-cert/<name>/current. E.g.
      "share.<domain>" for *.share.joshuabell.xyz (FLOWS-AUDIT.md §c).
    '';
  };
  options.fleet.wildcardCertPushPubKey = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = fleet.global.wildcardCertPushPubKey or null;
    description = ''
      Dedicated SSH public key for h005's wildcard-push
      (hosts/h005/wildcard-cert.nix), restricted to fleet-cert-receive.
      Set this (instead of relying on the shared nix2nix root key) once a
      dedicated `wildcard_push` key exists in sec, so a compromise of this
      narrow command can never be used for anything but pushing a cert pair.
    '';
  };

  config = {
    environment.systemPackages = [ receive ];
    systemd.tmpfiles.rules = map (n: "d /var/lib/fleet-cert/${n} 0750 root nginx -") certNames;
    users.users.root.openssh.authorizedKeys.keys =
      lib.optional (config.fleet.wildcardCertPushPubKey != null)
        ''command="/run/current-system/sw/bin/fleet-cert-receive",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc ${config.fleet.wildcardCertPushPubKey}'';
    # One-time migration of the flat pre-versioning layout. It runs during
    # activation, before nginx is reloaded with the current/ paths. The flat
    # files stay so an older generation still finds them.
    system.activationScripts.fleet-cert-migrate = {
      deps = [
        "users"
        "groups"
      ];
      text = ''
        if [ ! -e ${current} ] && [ -f ${dir}/fullchain.pem ] && [ -f ${dir}/key.pem ]; then
          s=$(${pkgs.openssl}/bin/openssl x509 -in ${dir}/fullchain.pem -noout -serial | cut -d= -f2)
          v=v-$(date -u +%Y%m%dT%H%M%S)-$s
          install -d -m 0750 -o root -g nginx ${dir}/$v
          cp -p ${dir}/fullchain.pem ${dir}/key.pem ${dir}/$v/
          ln -sfn $v ${dir}/.current.tmp
          mv -T ${dir}/.current.tmp ${current}
          echo "fleet-cert: migrated flat files to $v"
        fi
      '';
    };
  };
}
