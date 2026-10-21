# Public wildcard *.joshuabell.xyz + apex, issued on h005 (ROUTING-PLAN §8
# step 4): DNS-01 via bunny, whose key h005 already holds (sec-agent.nix).
# Pushed to the TLS terminators (o002 edge, h001 internal listener) over
# SSH after every issue/renew, plus a daily retry. Receivers:
# hosts/wildcard-cert-receiver.nix.
#
# Why push and not sec: sec only lets the `admin` role write, and only to
# existing paths (secrets_manager README "Authorization"), so a machine
# cannot publish a renewed cert into it. Why not pull: receivers would
# need a credential into h005; h005 already has root SSH on both targets.
#
# Receivers keep their own ACME setup until their nginx is switched to
# the pushed files, so this can run alongside the per-name certs.
{
  config,
  lib,
  pkgs,
  fleet,
  ...
}:
let
  domain = fleet.global.domain;
  certDir = config.security.acme.certs.${domain}.directory;
  # Same path on every receiver (wildcard-cert-receiver.nix).
  remoteDir = "/var/lib/fleet-cert/${domain}/current";
  # Pinned host keys (ssh-keyscan over the tailnet, 2026-10-21). A
  # rebuilt target needs its new key here before pushes work again.
  targets = {
    o002 = {
      ip = fleet.hosts.o002.overlayIp;
      hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAf4Tfw9fhqQ2oUwM7jGSkpvxdTCsFVlThVVpf8FoU08";
    };
    h001 = {
      ip = fleet.hosts.h001.overlayIp;
      hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGTAz6n35c3r8kSuWJM1JzMVx6jK+0EBwpJA5eTIvy3N";
    };
  };
  knownHosts = pkgs.writeText "wildcard-push-known-hosts" (
    lib.concatMapStrings (t: "${t.ip} ${t.hostKey}\n") (builtins.attrValues targets)
  );
  sshKey = "/var/lib/secrets_manager_hydrated/nix2nix_2026-03-15";
  push = pkgs.writeShellApplication {
    name = "wildcard-push";
    runtimeInputs = [
      pkgs.openssh
      pkgs.gnutar
      pkgs.coreutils
    ];
    text = ''
      # Every target is tried; the unit succeeds only if every receiver exited
      # 0 (ssh returns the remote status), otherwise it fails and is retried
      # daily.
      rc=0
      for t in ${lib.concatStringsSep " " (map (t: t.ip) (builtins.attrValues targets))}; do
        # The receiver stages the pair in a new version dir, swaps the
        # `current` symlink, runs nginx -t and reloads; on failure it restores
        # the previous version and exits non-zero (wildcard-cert-receiver.nix).
        if tar -C ${certDir} -cf - fullchain.pem key.pem \
          | timeout 60 ssh -i ${sshKey} -o BatchMode=yes -o IdentitiesOnly=yes \
              -o UserKnownHostsFile=${knownHosts} -o StrictHostKeyChecking=yes \
              "root@$t" fleet-cert-receive; then
          echo "pushed to $t"
        else
          echo "push to $t failed" >&2
          rc=1
        fi
      done
      exit "$rc"
    '';
  };
in
{
  security.acme.certs.${domain} = {
    inherit domain;
    extraDomainNames = [ "*.${domain}" ];
    # credentialFiles.BUNNY_API_KEY_FILE injected via sec-agent configChanges
    # (hosts/h005/sec-agent.nix).
    dnsProvider = "bunny";
    # Check propagation against public resolvers, not h005's own dnsmasq/
    # AdGuard (127.0.0.53), which can answer from cache before bunny has the
    # TXT. Apex + wildcard share _acme-challenge (two TXT values).
    dnsResolver = "1.1.1.1:53";
    extraLegoFlags = [
      "--dns.propagation-wait"
      "60s"
    ];
    # Only the push unit reads it; nginx on h005 doesn't serve these names.
    group = "acme";
    postRun = "systemctl start --no-block wildcard-push.service";
  };

  systemd.services.wildcard-push = {
    description = "Push the ${domain} wildcard cert to o002 and h001";
    after = [
      "network-online.target"
      "tailscaled-autoconnect.service"
      "acme-${domain}.service"
    ];
    wants = [ "network-online.target" ];
    # No cert yet (first issue still pending): nothing to push.
    unitConfig.ConditionPathExists = "${certDir}/key.pem";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe push;
    };
  };
  systemd.timers.wildcard-push = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
  };
}
