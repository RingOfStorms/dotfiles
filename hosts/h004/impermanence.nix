# Impermanence persistence for h004 (headless NAS). Most state comes from
# the shared sets in `flakes/impermanence/shared_persistence/`. SSH host keys
# are already persisted by the impermanence module (/persist/etc/ssh).
{ primaryUser, impermanence_mod }:
{ ... }:
let
  shared = impermanence_mod.lib.mergeSharedPersistence (
    with impermanence_mod.sharedPersistence;
    [
      essentials
      network_manager
      hardening
      tailscale
      timezone_cache
      atuin
      zoxide
      tmux
      direnv
      nvim_ros
    ]
  );
in
{
  environment.persistence."/persist" = {
    enable = true;
    hideMounts = true;
    directories = shared.system.directories ++ [
      "/var/lib/secrets_manager_hydrated"
      # NFSv4 client/lock state; keeps clients' grace-period reclaim working
      # across reboots.
      "/var/lib/nfs"
      # smartd attribute history (detects growing reallocated/pending counts).
      "/var/lib/smartmontools"
    ];
    files = shared.system.files ++ [ ];
    users."${primaryUser}" = {
      directories = shared.user.directories ++ [ ];
      files = shared.user.files ++ [ ];
    };
  };
}
