# Impermanence persistence for h005 (router). Most state comes from the shared
# sets in `flakes/impermanence/shared_persistence/`. SSH host keys are already
# persisted by the impermanence module (/persist/etc/ssh).
{ primaryUser, impermanence_mod }:
{ ... }:
let
  shared = impermanence_mod.lib.mergeSharedPersistence (
    with impermanence_mod.sharedPersistence;
    [
      essentials
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
      # Router state (dnsmasq leases, AdGuard, NUT) gets added here when the
      # router mods move over from h003.
    ];
    files = shared.system.files ++ [ ];
    users."${primaryUser}" = {
      directories = shared.user.directories ++ [ ];
      files = shared.user.files ++ [ ];
    };
  };
}
