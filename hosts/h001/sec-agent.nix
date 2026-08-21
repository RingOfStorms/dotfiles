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
    bunny_rw_dns_2026-03-15 = {
      remotePath = "machines/high-trust/bunny_rw_dns_2026-03-15";
      configChanges.security.acme.certs."joshuabell.xyz".credentialFiles.BUNNY_API_KEY_FILE = "$SECRET_PATH";
    };

    us_chi_wg_2026-03-15 = {
      remotePath = "machines/high-trust/us_chi_wg_2026-03-15";
      configChanges.nixarr.vpn.wgConf = "$SECRET_PATH";
    };

    zitadel_master_key_2026-03-15 = {
      remotePath = "machines/high-trust/zitadel_master_key_2026-03-15";
      mode = "0444";
      softDepend = [ "container@zitadel" ];
    };

    oauth2_proxy_key_file_2026-03-15 = {
      remotePath = "machines/high-trust/oauth2_proxy_key_file_2026-03-15";
      configChanges.services.oauth2-proxy.keyFile = "$SECRET_PATH";
    };

    openwebui_env_2026-03-15 = {
      remotePath = "machines/high-trust/openwebui_env_2026-03-15";
      softDepend = [ "open-webui" ];
    };

    # This is the preformatted EnvironmentFile consumed by LiteLLM. It is a
    # separate sec key because the old OpenBao template assembled it from the
    # openrouter api-key field, while sec-agent intentionally renders values
    # byte-for-byte.
    litellm-env = {
      remotePath = "machines/high-trust/litellm-env";
      softDepend = [ "litellm" ];
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
