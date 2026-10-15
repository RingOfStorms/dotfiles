# Host-specific sec-agent additions for h001.
#
# h001 continues to run the OpenBao server for the hosts that have not been
# deployed yet, but its own consumers read the sec-agent cache below. Keeping
# the two stores and rendered directories separate is what makes that
# dual-run safe.
{ inputs, constants, ... }:
import ../sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
  extraSecrets = {
    # Credentials of the shared `josh` atuin account, readable by the local
    # primary user's atuin-autologin.
    "atuin-key-josh_2026-03-15" = {
      remotePath = "machines/high-trust/atuin-key-josh_2026-03-15";
      field = "value";
      owner = constants.host.primaryUser;
      group = "users";
      mode = "0400";
      hardDepend = [ "atuin-autologin" ];
    };

    bunny_rw_dns_2026-03-15 = {
      remotePath = "machines/high-trust/bunny_rw_dns_2026-03-15";
      configChanges.security.acme.certs."joshuabell.xyz".credentialFiles.BUNNY_API_KEY_FILE =
        "$SECRET_PATH";
    };

    # Read by the arr container (containers/arr/container.nix) through the
    # secrets bind mount.
    us_chi_wg_2026-03-15 = {
      remotePath = "machines/high-trust/us_chi_wg_2026-03-15";
    };

    oauth2_proxy_key_file_2026-03-15 = {
      remotePath = "machines/high-trust/oauth2_proxy_key_file_2026-03-15";
      # Bound read-only into the trilium floating container.
      softDepend = [ "container@trilium" ];
    };

    openwebui_env_2026-03-15 = {
      remotePath = "machines/high-trust/openwebui_env_2026-03-15";
      softDepend = [ "container@open-webui" ];
    };

    # This is the preformatted EnvironmentFile consumed by LiteLLM. It is a
    # separate sec key because the old OpenBao template assembled it from the
    # openrouter api-key field, while sec-agent intentionally renders values
    # byte-for-byte.
    litellm-env = {
      remotePath = "machines/high-trust/litellm-env";
      softDepend = [ "container@litellm" ];
    };

    # pgBackRest conf fragment for the Life container ([global]
    # repo1-cipher-pass=...). Read by postgres inside the container; the host
    # postgres group has the same gid (config.ids.gids.postgres).
    life_pgbackrest_2026-09-30 = {
      remotePath = "machines/high-trust/life_pgbackrest_2026-09-30";
      group = "postgres";
      mode = "0440";
      softDepend = [ "container@life" ];
    };

    # EnvironmentFile for Life's nightly restic backup. systemd reads it as
    # root before dropping to `life`, so the default root:root 0400 is right.
    life_backup_env_2026-09-30 = {
      remotePath = "machines/high-trust/life_backup_env_2026-09-30";
      softDepend = [ "container@life" ];
    };

    # EnvironmentFile for h001's restic backup (mods/restic-backup.nix):
    # RESTIC_REPOSITORY, RESTIC_PASSWORD and the backend credentials.
    restic_h001_env_2026-10-01 = {
      remotePath = "machines/high-trust/restic_h001_env_2026-10-01";
      configChanges.services.restic.backups.h001.environmentFile = "$SECRET_PATH";
    };

    sabnzbd_api_key_2026-07-15 = {
      remotePath = "machines/high-trust/sabnzbd_api_key_2026-07-15";
      field = "api-key";
      group = "media";
      mode = "0440";
    };

    nzbgeek_api_key_2026-07-15 = {
      remotePath = "machines/high-trust/nzbgeek_api_key_2026-07-15";
      field = "api-key";
      group = "prowlarr-api";
      mode = "0440";
    };

    vaultwarden_env_2026-03-15 = {
      remotePath = "machines/high-trust/vaultwarden_env_2026-03-15";
      softDepend = [ "container@vaultwarden" ];
    };
  };
}
