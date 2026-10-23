# Receiver for the public wildcard pushed by h005 (hosts/h005/wildcard-cert.nix,
# ROUTING-PLAN §8 step 4). h005 runs `fleet-cert-receive` over root SSH with
# a tar of fullchain.pem + key.pem on stdin.
#
# Layout (one directory per pushed pair, swapped by one symlink rename):
#   /var/lib/fleet-cert/<domain>/v-<utc time>-<serial>/{fullchain,key}.pem
#   /var/lib/fleet-cert/<domain>/current -> v-...
# Sites only name current/fullchain.pem and current/key.pem, so they always see
# both files from the same version. The receiver switches `current`, runs
# `nginx -t` and reloads. If either fails it points `current` back at the
# previous version and exits non-zero, which fails h005's push. It keeps the
# last 3 versions.
#
# Importing this does not change nginx. A host opts in per vhost with
# `fleet.wildcardTls` / `fleet.wildcardCertDir` once `current` exists: nginx
# refuses to start on a missing certificate file. The activation script below
# migrates the pre-versioning flat files into a version dir, so `current`
# exists before the switched sites are reloaded.
{
  config,
  lib,
  pkgs,
  fleet,
  ...
}:
let
  domain = fleet.global.domain;
  dir = "/var/lib/fleet-cert/${domain}";
  current = "${dir}/current";
  nginxCfg = config.services.nginx;
  # The config path differs per host (o002 has no /etc/nginx/nginx.conf):
  # test exactly what the running unit was started with.
  nginxTest = ''"${nginxCfg.package}/bin/nginx" -t -c "$(systemctl show -p ExecStart --value nginx | grep -o -- '-c [^ ;]*' | head -1 | cut -d' ' -f2)"'';

  # Point `current` at $1 (a v-* name) atomically.
  swap = ''
    swap() {
      ln -sfn "$1" ${dir}/.current.tmp
      mv -T ${dir}/.current.tmp ${current}
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
      install -d -m 0750 -o root -g nginx ${dir}
      tmp=$(mktemp -d ${dir}/.in.XXXXXX)
      trap 'rm -rf "$tmp"' EXIT
      tar -C "$tmp" -xf - fullchain.pem key.pem
      # Refuse garbage and mismatched pairs before touching anything live.
      openssl x509 -in "$tmp/fullchain.pem" -noout -checkend 86400
      [ "$(openssl x509 -in "$tmp/fullchain.pem" -noout -pubkey | sha256sum)" = \
        "$(openssl pkey -in "$tmp/key.pem" -pubout | sha256sum)" ]
      serial=$(openssl x509 -in "$tmp/fullchain.pem" -noout -serial | cut -d= -f2)

      prev=$(readlink ${current} || true)
      if [ -n "$prev" ] && cmp -s "$tmp/fullchain.pem" "${dir}/$prev/fullchain.pem" \
        && cmp -s "$tmp/key.pem" "${dir}/$prev/key.pem"; then
        echo "fleet-cert: unchanged ($prev)"
        exit 0
      fi

      chown root:nginx "$tmp" "$tmp/fullchain.pem" "$tmp/key.pem"
      chmod 0750 "$tmp"
      chmod 0644 "$tmp/fullchain.pem"
      chmod 0640 "$tmp/key.pem"
      new="v-$(date -u +%Y%m%dT%H%M%S)-$serial"
      mv -T "$tmp" "${dir}/$new"
      trap - EXIT

      swap "$new"
      if systemctl is-active --quiet nginx; then
        if ! ${nginxTest} || ! systemctl reload nginx; then
          echo "fleet-cert: nginx rejected $new, rolling back to ''${prev:-nothing}" >&2
          if [ -n "$prev" ]; then
            swap "$prev"
            systemctl reload nginx || true
          else
            rm -f ${current}
          fi
          rm -rf "${dir}/$new"
          exit 1
        fi
      fi

      # Keep the last 3 versions (names sort by time); never the live one.
      find ${dir} -mindepth 1 -maxdepth 1 -type d -name 'v-*' -printf '%f\n' \
        | sort -r | tail -n +4 | while read -r old; do
          [ "$old" = "$new" ] || rm -rf "${dir}/$old"
        done
      echo "fleet-cert: current -> $new ($(openssl x509 -in ${current}/fullchain.pem -noout -enddate))"
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
    systemd.tmpfiles.rules = [ "d ${dir} 0750 root nginx -" ];
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
