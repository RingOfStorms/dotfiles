# Impermanence persistence declarations for joe (primary desktop /
# gaming rig). Most state comes from the shared persistence sets in
# `flakes/impermanence/shared_persistence/`. Only host-specific
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
      "/var/lib/secrets_manager_hydrated"
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
