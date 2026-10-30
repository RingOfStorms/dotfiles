# Public wildcard *.joshuabell.xyz + apex, issued on h005 (ROUTING-PLAN §8
# step 4): DNS-01 via bunny, whose key h005 already holds (sec-agent.nix).
# Pushed to every container-host TLS terminator (every host with container
# routes, plus joe and lio, plus o002 the public edge; FLOWS-AUDIT target
# design (a): each terminates TLS for its own routes) over SSH after every
# issue/renew, plus a daily retry. Also issues
# *.share.joshuabell.xyz (FLOWS-AUDIT.md §c, local temporary sharing),
# pushed to o002 ONLY (`fleet-cert-receive share.joshuabell.xyz`). Receivers:
# hosts/_shared_assets/utilities/wildcard-cert-receiver.nix.
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
  constants,
  ...
}:
let
  domain = fleet.global.domain;
  shareDomain = "share.${domain}";
  certDir = config.security.acme.certs.${domain}.directory;
  shareCertDir = config.security.acme.certs.${shareDomain}.directory;
  # Push targets: every host with container routes (containers/lib.nix
  # routeNamesByHost), plus joe and lio explicitly (FLOWS-AUDIT target
  # design (a): every container host terminates its own TLS, including
  # low-route-count hosts not yet carrying a non-local http route), plus
  # o002 (the public edge). Pinned host keys: fleet.nix hosts.<h>.sshHostKey.
  routeHosts = builtins.attrNames (
    (import ../../containers/lib.nix).routeNamesByHost ../../containers
  );
  targetNames = lib.unique (
    routeHosts
    ++ [
      "joe"
      "lio"
      "h003" # container host with backups but no routes yet: must terminate TLS before a `move` lands
      "o002"
    ]
  );
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
  # H2 (key minimisation): this currently rides on the shared nix2nix root
  # key, which also unlocks every other fleet host -- more reach than
  # "push a cert pair to two receivers" needs. Swap-in path once a
  # dedicated key exists in sec:
  #   1. Generate an ed25519 keypair; store the private half in sec as
  #      `wildcard_push_2026-XX-XX` (machines/high-trust), the public half
  #      goes in each receiver's `fleet.wildcardCertPushPubKey`
  #      (hosts/_shared_assets/utilities/wildcard-cert-receiver.nix) -- never the shared
  #      nix2nixMatchBlockHosts set.
  #   2. Add a `wildcard_push_2026-XX-XX` secret here (hosts/h005/sec-agent.nix)
  #      with a `configChanges` or local secretFile pointing sshKey below at
  #      its rendered path instead of nix2nix's.
  #   3. Flip the line below to the new path; the command= restriction on
  #      each receiver's authorized_keys entry means this key can only ever
  #      invoke fleet-cert-receive, so losing it exposes nothing else.
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
