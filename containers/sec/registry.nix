# The sec key registry (moved verbatim from hosts/h001/mods/sec.nix).
# Full mirror of the KV registry. Every key is listed here so the
# reconciler creates stubs for all of them. Values start as
# `TODO:replace_me` and are filled in through the UI; the
# reconciler never overwrites a value that is already set.
#
# Access is granted explicitly per key — no prefix matching. A
# `role` grant binds to a Zitadel role claim value; a `sub` grant
# binds to a specific machine identity's service-account userId.
# The old OpenBao model gave `device_high_trust` read on all
# machines/high-trust/* and machines/low-trust/*, and
# `device_low_trust` read on machines/low-trust/*. The new model
# requires an explicit grant on each key, so every high-trust key
# carries a `device_high_trust` role grant and every low-trust key
# carries both `device_high_trust` and `device_low_trust` (high-trust
# is a superset, as in OpenBao). Per-host keys use `sub` grants that
# will be filled in with real Zitadel service-account userIds.
{
  # ── high-trust: SSH keys ──────────────────────────────────────
  "machines/high-trust/nix2nix_2026-03-15" = {
    fields = [ "value" ];
    description = "Inter-machine SSH key (nix2nix).";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };
  "machines/high-trust/nix2github_2026-03-15" = {
    fields = [ "value" ];
    description = "External GitHub SSH key (nix2github).";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };
  "machines/high-trust/nix2gitforgejo_2026-03-15" = {
    fields = [ "value" ];
    description = "External Forgejo SSH key (nix2gitforgejo).";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };
  "machines/by-host/h005/wildcard_push_2026-10-22" = {
    fields = [ "value" ];
    description = "Dedicated SSH private key for h005 wildcard-push (restricted to fleet-cert-receive on h001 and o002).";
    access = [
      {
        type = "sub";
        value = "395294573078773763";
      }
    ];
  };
  "machines/by-host/h005/ups_shutdown_2026-10-22" = {
    fields = [ "value" ];
    description = "Dedicated SSH private key for h005 NUT ups-shutdown (restricted to fleet-ups-shutdown on h001 and h004).";
    access = [
      {
        type = "sub";
        value = "395294573078773763";
      }
    ];
  };
  "machines/high-trust/remote_lio_builds_2026-10-22" = {
    fields = [ "value" ];
    description = "Dedicated SSH private key for remote_lio_builds distributed Nix builds on lio (restricted to nix-daemon/nix-store).";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };

  # ── high-trust: tailnet ───────────────────────────────────────
  "machines/high-trust/headscale_auth_2026-03-15" = {
    fields = [ "value" ];
    description = "Headscale auth key for high-trust hosts.";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };

  # ── high-trust: nix / build ───────────────────────────────────
  "machines/high-trust/github_read_token_2026-03-15" = {
    fields = [ "value" ];
    description = "GitHub read-only token for nix fetches.";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };

  # ── high-trust: h001 service secrets ──────────────────────────
  "machines/high-trust/bunny_rw_dns_2026-03-15" = {
    fields = [ "value" ];
    description = "bunny.net DNS API key (h005: public + ts wildcard ACME, DDNS, fleet-edge dns-plan).";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };
  "machines/high-trust/us_chi_wg_2026-03-15" = {
    fields = [ "value" ];
    description = "WireGuard config for US-Chicago exit node (nixarr VPN).";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };
  "machines/high-trust/oauth2_proxy_key_file_2026-03-15" = {
    fields = [ "value" ];
    description = "oauth2-proxy session key file.";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };
  "machines/high-trust/openwebui_env_2026-03-15" = {
    fields = [ "value" ];
    description = "Open WebUI env file (WEBUI_SECRET_KEY + Zitadel OAuth creds).";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };
  "machines/high-trust/openrouter_2026-03-15" = {
    fields = [ "api-key" ];
    description = "OpenRouter API key.";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };
  "machines/high-trust/litellm-env" = {
    fields = [ "value" ];
    description = "LiteLLM EnvironmentFile (OpenRouter API key).";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };
  "machines/high-trust/life_pgbackrest_2026-09-30" = {
    fields = [ "value" ];
    description = "Life pgBackRest conf fragment ([global] repo1-cipher-pass=...).";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };
  "machines/high-trust/life_backup_env_2026-09-30" = {
    fields = [ "value" ];
    description = "Life nightly backup EnvironmentFile (RESTIC_REPOSITORY, RESTIC_PASSWORD, offsite creds).";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };
  "machines/high-trust/restic_h001_env_2026-10-01" = {
    fields = [ "value" ];
    description = "h001 restic EnvironmentFile (RESTIC_REPOSITORY, RESTIC_PASSWORD, offsite backend creds).";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };
  "machines/high-trust/sabnzbd_api_key_2026-07-15" = {
    fields = [ "api-key" ];
    description = "Sabnzbd API key (nixarr).";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };
  "machines/high-trust/nzbgeek_api_key_2026-07-15" = {
    fields = [ "api-key" ];
    description = "NZBGeek API key (nixarr prowlarr).";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };

  # ── high-trust: per-host service secrets ──────────────────────
  "machines/high-trust/atuin-key-josh_2026-03-15" = {
    fields = [ "value" ];
    description = "Atuin sync key for josh (3-line: user, password, key).";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };
  "machines/high-trust/vaultwarden_env_2026-03-15" = {
    fields = [ "value" ];
    description = "Vaultwarden env file (bind-mounted into container).";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
    ];
  };

  # ── low-trust (joe, i001) ────────────────────────────────
  "machines/low-trust/headscale_auth_lowtrust_2026-03-15" = {
    fields = [ "value" ];
    description = "Headscale auth key for low-trust hosts.";
    access = [
      {
        type = "role";
        value = "device_high_trust";
      }
      {
        type = "role";
        value = "device_low_trust";
      }
    ];
  };

  # ── per-host: h003 ────────────────────────────────────────────
  "machines/by-host/h003/hass_isp_speedtest_token" = {
    fields = [ "value" ];
    description = "Home Assistant long-lived token (h003 ISP speedtest).";
    access = [
      {
        type = "sub";
        value = "364267072236027907";
      }
    ];
  };

  # ── per-host: h005 ────────────────────────────────────────────
  "machines/by-host/h005/hass_isp_speedtest_token" = {
    fields = [ "value" ];
    description = "Home Assistant long-lived token (h005 ISP speedtest).";
    access = [
      {
        type = "sub";
        value = "395294573078773763";
      }
    ];
  };
}
