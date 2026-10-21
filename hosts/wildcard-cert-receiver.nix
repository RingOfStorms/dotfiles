# Receiver for the public wildcard pushed by h005 (hosts/h005/wildcard-cert.nix,
# ROUTING-PLAN §8 step 4). h005 runs `fleet-cert-receive` over root SSH with
# a tar of fullchain.pem + key.pem on stdin; it lands in
# /var/lib/fleet-cert/<domain>/ (owned root:nginx, key 0640) and nginx is
# reloaded by a path unit.
#
# Importing this does not change nginx. A host opts in per vhost with
# `wildcardTls` (below) once the first push has landed: nginx refuses to
# start on a missing certificate file.
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
  receive = pkgs.writeShellApplication {
    name = "fleet-cert-receive";
    runtimeInputs = [
      pkgs.gnutar
      pkgs.coreutils
      pkgs.openssl
    ];
    text = ''
      umask 077
      install -d -m 0750 -o root -g nginx ${dir}
      tmp=$(mktemp -d ${dir}/.in.XXXXXX)
      trap 'rm -rf "$tmp"' EXIT
      tar -C "$tmp" -xf - fullchain.pem key.pem
      # Refuse garbage and mismatched pairs before replacing anything.
      openssl x509 -in "$tmp/fullchain.pem" -noout -checkend 86400
      [ "$(openssl x509 -in "$tmp/fullchain.pem" -noout -pubkey | sha256sum)" = \
        "$(openssl pkey -in "$tmp/key.pem" -pubout | sha256sum)" ]
      chown root:nginx "$tmp/fullchain.pem" "$tmp/key.pem"
      chmod 0644 "$tmp/fullchain.pem"
      chmod 0640 "$tmp/key.pem"
      mv -f "$tmp/key.pem" ${dir}/key.pem.new
      mv -f "$tmp/fullchain.pem" ${dir}/fullchain.pem.new
      mv -f ${dir}/key.pem.new ${dir}/key.pem
      mv -f ${dir}/fullchain.pem.new ${dir}/fullchain.pem
      echo "fleet-cert: $(openssl x509 -in ${dir}/fullchain.pem -noout -enddate)"
    '';
  };
in
{
  options.fleet.wildcardTls = lib.mkOption {
    type = lib.types.attrs;
    readOnly = true;
    description = "nginx vhost TLS attrs that use the pushed wildcard.";
    default = {
      forceSSL = true;
      sslCertificate = "${dir}/fullchain.pem";
      sslCertificateKey = "${dir}/key.pem";
    };
  };

  config = {
    environment.systemPackages = [ receive ];
    systemd.tmpfiles.rules = [ "d ${dir} 0750 root nginx -" ];
    systemd.paths.fleet-cert-reload = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = "${dir}/fullchain.pem";
    };
    systemd.services.fleet-cert-reload = {
      description = "Reload nginx after a pushed wildcard cert";
      serviceConfig.Type = "oneshot";
      script = ''
        if systemctl is-active --quiet nginx; then
          systemctl reload nginx
        fi
      '';
    };
  };
}
