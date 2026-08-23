# Bootstrap persistence for an Oracle cloud VM.
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
    ]
  );
in
{
  environment.persistence."/persist" = {
    enable = true;
    hideMounts = true;
    directories = shared.system.directories ++ [
      # sec-agent: rendered secret blobs written by the secrets manager
      # agent. Must survive the impermanence root-wipe so services can
      # read their secrets across reboots even before the agent re-fetches.
      "/var/lib/secrets_manager_hydrated"
    ];
    files = shared.system.files ++ [ ];
    users."${primaryUser}" = {
      directories = shared.user.directories ++ [ ];
      files = shared.user.files ++ [ ];
    };
  };
}
