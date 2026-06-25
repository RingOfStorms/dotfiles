# Bootstrap persistence for o002 (Oracle cloud VM).
#
# Base-survival set only: enough to boot, keep machine identity, join the
# tailnet, and fetch secrets across the impermanence root-wipe. Service
# data dirs (vaultwarden, postgres, acme, ...) are added when services are
# ported on top.
#
# Takes the impermanence flake as `impermanence_mod` and the primary user
# (root on cloud boxes) so the merged shared sets resolve user paths.
{ primaryUser, impermanence_mod }:
{ ... }:
let
  shared = impermanence_mod.lib.mergeSharedPersistence (
    with impermanence_mod.sharedPersistence;
    [
      essentials # /var/log, /var/lib/nixos, /machine-key.json, /etc/machine-id, ...
      tailscale  # /var/lib/tailscale node identity
      openbao    # /run/openbao, /var/lib/openbao-secrets
    ]
  );
in
{
  environment.persistence."/persist" = {
    enable = true;
    hideMounts = true;
    directories = shared.system.directories ++ [
      # Headscale coordination DB (node registrations) — must survive the
      # impermanence root-wipe or every node would have to re-register.
      "/var/lib/headscale"
      # ACME state: issued Let's Encrypt certs + the lego account key. MUST be
      # persisted. o002 fronts ~25 vhosts; re-issuing them all on every boot
      # risks LE rate limits, and — as actually happened — if a single re-order
      # hits a transient LE error, nginx stays on the minica self-signed
      # placeholder, which takes down headscale's TLS and therefore the entire
      # tailnet control plane. Persisting the lego account key also avoids the
      # new-account-per-boot limit.
      #
      # The earlier "empty /persist dir shadowed the live certs on first
      # activation" failure is avoided by pre-seeding /persist from the live
      # certs before the first deploy that enables this:
      #   rsync -aH /var/lib/acme/ /persist/var/lib/acme/
      # so the bind-mount surfaces real certs, never an empty dir.
      "/var/lib/acme"
    ];
    files = shared.system.files ++ [ ];
    users."${primaryUser}" = {
      directories = shared.user.directories ++ [ ];
      files = shared.user.files ++ [ ];
    };
  };
}
