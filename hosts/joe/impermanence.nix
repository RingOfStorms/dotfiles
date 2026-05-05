# Impermanence persistence declarations for joe (primary desktop /
# gaming rig). Most state comes from the shared persistence sets in
# `flakes/impermanence/shared_persistence/`. Only host-specific
# entries live inline below.
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
      upower
      tailscale
      openbao
      pipewire
      timezone_cache
      flatpak
      atuin
      zoxide
      tmux
      direnv
      opencode
      nvim_ros
      de_plasma
      chrome
      steam
      jellyfin_media_player
    ]
  );
in
{
  environment.persistence."/persist" = {
    enable = true;
    hideMounts = true;
    directories = shared.system.directories ++ [
      # llama.cpp server state + model cache (downloaded GGUFs from
      # Hugging Face — typically the largest dir on this host).
      "/var/lib/llama-cpp"
      "/var/cache/llama-cpp"

      # Kokoro TTS model cache and any custom voice packs.
      "/var/lib/kokoro-tts"

      # Stable Diffusion Forge workspace, models, generated images.
      "/var/lib/forge"
    ];
    files = shared.system.files ++ [ ];
    users."${primaryUser}" = {
      directories = shared.user.directories ++ [
        # Vesktop (Discord client) settings, login session, plugin data.
        ".config/vesktop"

        # Prism Launcher (Minecraft): instances, mods, accounts,
        # settings.
        ".local/share/PrismLauncher"
      ];
      files = shared.user.files ++ [ ];
    };
  };
}
