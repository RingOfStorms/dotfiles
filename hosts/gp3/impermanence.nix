# Impermanence persistence declarations for GPD Pocket 3 (media /
# gaming TV box). Most state comes from the shared persistence sets
# in `flakes/impermanence/shared_persistence/`. Only host-specific
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
      atuin
      zoxide
      tmux
      direnv
      opencode
      nvim_ros
      de_plasma
      chrome
      bitwarden
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
      # gnome-remote-desktop daemon state — TLS cert/key, paired
      # device list. Regenerated if missing, but persisting avoids
      # RDP client re-trust prompts.
      "/var/lib/gnome-remote-desktop"
    ];
    files = shared.system.files ++ [ ];
    users."${primaryUser}" = {
      directories = shared.user.directories ++ [
        # gnome-remote-desktop user-level config: TLS cert/key,
        # credentials store, paired-clients list. grdctl writes here
        # (the grd-configure user unit on every boot, but persisting
        # avoids regenerating the cert each reboot which would force
        # RDP clients to re-trust on every reboot).
        ".config/gnome-remote-desktop"
        ".local/share/gnome-remote-desktop"

        # gnome-keyring storage. GRD writes the RDP password here
        # via libsecret. Without persistence, the keyring would be
        # recreated empty every boot and grdctl would have to write
        # the password back from openbao on every login.
        ".local/share/keyrings"
      ];
      files = shared.user.files ++ [ ];
    };
  };
}
