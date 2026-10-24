# Impermanence persistence declarations for GPD Pocket 3 (trusted
# mobile work laptop). Most state comes from the shared persistence sets
# in `flakes/impermanence/shared_persistence/`. Only host-specific
# entries live inline below.
{ primaryUser, impermanence }:
{ ... }:
let
  shared = impermanence.lib.mergeSharedPersistence (
    with impermanence.sharedPersistence;
    [
      essentials
      xdg_user_dirs
      network_manager
      bluetooth
      iwd
      hardening
      upower
      tailscale
      pipewire
      timezone_cache
      atuin
      zoxide
      tmux
      direnv
      opencode
      nvim_ros
      de_plasma
      chrome
      firefox
      bitwarden
      jellyfin_media_player
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
      # stt_ime whisper model (~488MB small.en); otherwise re-downloaded every boot.
      directories = shared.user.directories ++ [ ".cache/stt-stream" ];
      files = shared.user.files ++ [ ];
    };
  };
}
