# Impermanence persistence declarations for i001 (install host /
# low-trust kiosk). Most state comes from the shared persistence sets
# in `flakes/impermanence/shared_persistence/`. Only host-specific
# entries live inline below.
{ impermanence_mod }:
{ ... }:
let
  user = "luser";
  shared = impermanence_mod.lib.mergeSharedPersistence (
    with impermanence_mod.sharedPersistence;
    [
      essentials
      network_manager
      bluetooth
      iwd
      hardening
      tailscale
      openbao
      pipewire
      timezone_cache
      atuin
      zoxide
      nvim_ros
      chrome
      de_plasma
    ]
  );
in
{
  environment.persistence."/persist" = {
    enable = true;
    hideMounts = true;
    directories = shared.system.directories ++ [ ];
    files = shared.system.files ++ [ ];
    users."${user}" = {
      directories = shared.user.directories ++ [ ];
      files = shared.user.files ++ [ ];
    };
  };
}
