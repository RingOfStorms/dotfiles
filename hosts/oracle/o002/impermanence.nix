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
    directories = shared.system.directories ++ [ ];
    files = shared.system.files ++ [ ];
    users."${primaryUser}" = {
      directories = shared.user.directories ++ [ ];
      files = shared.user.files ++ [ ];
    };
  };
}
