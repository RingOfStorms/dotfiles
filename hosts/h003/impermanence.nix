# Impermanence persistence for h003 (headless containers host). Most state comes from
# the shared sets in `flakes/impermanence/shared_persistence/`. SSH host keys
# are already persisted by the impermanence module (/persist/etc/ssh).
{ primaryUser, impermanence }:
{ ... }:
let
  shared = impermanence.lib.mergeSharedPersistence (
    with impermanence.sharedPersistence;
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
    ];
    files = shared.system.files ++ [ ];
    users."${primaryUser}" = {
      directories = shared.user.directories ++ [ ];
      files = shared.user.files ++ [ ];
    };
  };
}
