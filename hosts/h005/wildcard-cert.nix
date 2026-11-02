# h005 holds the Bunny DNS credential and pushes renewed wildcard certs to
# container hosts and o002. The share wildcard goes only to o002.
# Push avoids giving receivers credentials into the router; sec permits
# writes only by admins to existing paths, not by renewing machines.
{
  config,
  lib,
  pkgs,
  fleet,
  constants,
  ...
}:
let
  domain = fleet.global.domain;
  shareDomain = "share.${domain}";
  certDir = config.security.acme.certs.${domain}.directory;
  shareCertDir = config.security.acme.certs.${shareDomain}.directory;
  # Push to every container host and the public edge, independent of placement.
  # Pinned host keys: fleet.nix hosts.<h>.sshHostKey.
  targetNames = [ "h001" "h003" "joe" "lio" "o002" ];
  targets = builtins.listToAttrs (
    map (h: {
      name = h;
      value = {
        ip = fleet.hosts.${h}.overlayIp;
        hostKey = fleet.hosts.${h}.sshHostKey;
      };
    }) targetNames
  );
  knownHosts = pkgs.writeText "wildcard-push-known-hosts" (
    lib.concatMapStrings (t: "${t.ip} ${t.hostKey}\n") (builtins.attrValues targets)
  );
  # The dedicated key is restricted to fleet-cert-receive on each receiver.
  sshKey = "/var/lib/secrets_manager_hydrated/wildcard_push_2026-10-22";
  mkPush =
    {
      name,
      certName,
      certDir',
      pushTargets,
    }:
    pkgs.writeShellApplication {
      inherit name;
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
        # shellcheck disable=SC2043 # pushTargets can be a single host (e.g.
        # wildcard-share-push, o002 only); the loop still works for more.
        for t in ${lib.concatStringsSep " " (map (t: t.ip) (builtins.attrValues pushTargets))}; do
          # The receiver stages the pair in a new version dir, swaps the
          # `current` symlink, runs nginx -t and reloads; on failure it restores
          # the previous version and exits non-zero (wildcard-cert-receiver.nix).
          if tar -C ${certDir'} -cf - fullchain.pem key.pem \
            | timeout 60 ssh -i ${sshKey} -o BatchMode=yes -o IdentitiesOnly=yes \
                -o UserKnownHostsFile=${knownHosts} -o StrictHostKeyChecking=yes \
                "root@$t" "fleet-cert-receive ${certName}"; then
            echo "pushed ${certName} to $t"
          else
            echo "push ${certName} to $t failed" >&2
            rc=1
          fi
        done
        exit "$rc"
      '';
    };
  push = mkPush {
    name = "wildcard-push";
    certName = domain;
    certDir' = certDir;
    pushTargets = targets;
  };
  # *.share.<domain> (FLOWS-AUDIT.md §c) is only ever terminated on o002.
  sharePush = mkPush {
    name = "wildcard-share-push";
    certName = shareDomain;
    certDir' = shareCertDir;
    pushTargets = {
      inherit (targets) o002;
    };
  };
in
{
  security.acme = {
    acceptTerms = true;
    defaults.email = fleet.global.acmeEmail;
  };
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

  security.acme.certs.${shareDomain} = {
    domain = shareDomain;
    extraDomainNames = [ "*.${shareDomain}" ];
    # credentialFiles.BUNNY_API_KEY_FILE injected via sec-agent configChanges
    # (hosts/h005/sec-agent.nix).
    dnsProvider = "bunny";
    dnsResolver = "1.1.1.1:53";
    extraLegoFlags = [
      "--dns.propagation-wait"
      "60s"
    ];
    group = "acme";
    postRun = "systemctl start --no-block wildcard-share-push.service";
  };

  systemd.services.wildcard-push = {
    description = "Push the ${domain} wildcard cert to every container-host TLS terminator";
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
  systemd.services.wildcard-share-push = {
    description = "Push the ${shareDomain} wildcard cert to o002 (FLOWS-AUDIT.md §c)";
    after = [
      "network-online.target"
      "tailscaled-autoconnect.service"
      "acme-${shareDomain}.service"
    ];
    wants = [ "network-online.target" ];
    unitConfig.ConditionPathExists = "${shareCertDir}/key.pem";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe sharePush;
    };
  };
  systemd.timers.wildcard-share-push = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
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
