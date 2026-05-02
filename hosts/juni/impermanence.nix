# Impermanence persistence declarations for juni (KDE Plasma 6 laptop).
# Most state comes from the shared persistence sets in
# `flakes/impermanence/shared_persistence/`. Only host-specific entries
# live inline below.
{ primaryUser, impermanence_mod }:
{ ... }:
let
  shared = impermanence_mod.lib.mergeSharedPersistence (
    with impermanence_mod.sharedPersistence;
    [
      essentials
      xdg_user_dirs
      network_manager
      bluetooth
      iwd
      hardening
      tailscale
      upower
      pipewire
      openbao
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
    directories = shared.system.directories ++ [ ];
    files = shared.system.files ++ [ ];
    users."${primaryUser}" = {
      directories = shared.user.directories ++ [
        # Secondary Chrome profile for the work account (Tempus).
        ".config/google-chrome-tempus"

        # Hugging Face hub cache (used by hf-hub for whisper.cpp etc.).
        ".cache/huggingface"

        # LM Studio: downloaded models, chats, settings, bundled
        # runtime. Easily multi-GB once a model is pulled.
        ".lmstudio"
      ];
      files = shared.user.files ++ [ ];
    };
  };
}
