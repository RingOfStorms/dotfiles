# `sec` — the secrets manager that will replace OpenBao.
#
# During the migration this runs ALONGSIDE OpenBao on the same host. That
# is only safe because nothing is shared:
#
#   port        8300                       (openbao: 8200)
#   data        /var/lib/secrets_manager    (openbao: /var/lib/openbao)
#   hostname    secrets.joshuabell.xyz      (openbao: sec.joshuabell.xyz)
#   units       sec.service                 (openbao: openbao*.service)
#
# The `sec` CLI is deliberately NOT installed (installCli stays false):
# the secrets-bao module already puts a shell script named `sec` on PATH,
# and two different programs with one name is a footgun. The server does
# not need the binary on PATH — its unit calls an absolute store path.
# Flip installCli on once secrets-bao is gone from this host.
#
# The desired state below mirrors the full OpenBao KV registry from
# hosts/h001/mods/openbao/openbao-config.nix. Values start as
# `TODO:replace_me` stubs and are filled in through the UI; the
# reconciler never overwrites a value that is already set.
{
  inputs,
  constants,
  fleet,
  ...
}:
let
  c = constants.services.sec;
  domain = fleet.global.domain;
in
{
  imports = [ inputs.secrets_manager.nixosModules.server ];

  ringofstorms.secrets.server = {
    enable = true;

    listen = "127.0.0.1:${toString c.port}";
    inherit (c) dataDir domain;

    # Reuse the wildcard cert nginx.nix already obtains. `secrets` is a
    # single label under joshuabell.xyz, so *.joshuabell.xyz covers it
    # and no extraDomainNames entry is needed.
    useACMEHost = domain;

    # The key is generated into dataDir on first start and then never
    # touched again. BACK IT UP. Without it every stored value is
    # permanently undecryptable — there is no recovery path.
    generateKey = true;

    # Declarative mode: Nix owns the key set. The server refuses runtime
    # key creation/deletion and grant mutation — only values may be
    # written through the UI. The reconciler prunes any key not declared
    # below (tombstoning it into secret_versions first). Flip this off
    # only if you want the database to be the sole source of truth.
    declarative = true;

    zitadel = {
      issuer = "https://${constants.services.zitadel.domain}";
      # Same Zitadel project the OpenBao JWT auth method binds to, so the
      # machine identities that exist today work here unchanged.
      projectId = "344379162166820867";
      claim = "flatRolesClaim";

      # Admin UI sign-in. The clientId is the Zitadel application's
      # client ID; the server refuses the OIDC flow while this is empty,
      # so a half-finished setup fails closed rather than accidentally
      # exposing an unauthenticated UI.
      clientId = "384856081475633155";
      redirectUri = "https://${c.domain}/ui/callback";
    };

    # Full mirror of the OpenBao KV registry. Every key that OpenBao
    # declares in hosts/h001/mods/openbao/openbao-config.nix is listed
    # here so the reconciler creates stubs for all of them. Values
    # start as `TODO:replace_me` and are filled in through the UI; the
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
    secrets = {
      # ── high-trust: SSH keys ──────────────────────────────────────
      "machines/high-trust/nix2nix_2026-03-15" = {
        fields = [ "value" ];
        description = "Inter-machine SSH key (nix2nix).";
        access = [ { type = "role"; value = "device_high_trust"; } ];
      };
      "machines/high-trust/nix2github_2026-03-15" = {
        fields = [ "value" ];
        description = "External GitHub SSH key (nix2github).";
        access = [ { type = "role"; value = "device_high_trust"; } ];
      };
      "machines/high-trust/nix2gitforgejo_2026-03-15" = {
        fields = [ "value" ];
        description = "External Forgejo SSH key (nix2gitforgejo).";
        access = [ { type = "role"; value = "device_high_trust"; } ];
      };

      # ── high-trust: tailnet ───────────────────────────────────────
      "machines/high-trust/headscale_auth_2026-03-15" = {
        fields = [ "value" ];
        description = "Headscale auth key for high-trust hosts.";
        access = [ { type = "role"; value = "device_high_trust"; } ];
      };

      # ── high-trust: nix / build ───────────────────────────────────
      "machines/high-trust/github_read_token_2026-03-15" = {
        fields = [ "value" ];
        description = "GitHub read-only token for nix fetches.";
        access = [ { type = "role"; value = "device_high_trust"; } ];
      };

      # ── high-trust: h001 service secrets ──────────────────────────
      "machines/high-trust/bunny_rw_dns_2026-03-15" = {
        fields = [ "value" ];
        description = "bunny.net DNS API key (ACME wildcard + h003 DDNS).";
        access = [ { type = "role"; value = "device_high_trust"; } ];
      };
      "machines/high-trust/us_chi_wg_2026-03-15" = {
        fields = [ "value" ];
        description = "WireGuard config for US-Chicago exit node (nixarr VPN).";
        access = [ { type = "role"; value = "device_high_trust"; } ];
      };
      "machines/high-trust/zitadel_master_key_2026-03-15" = {
        fields = [ "value" ];
        description = "Zitadel master encryption key (base64-encoded).";
        access = [ { type = "role"; value = "device_high_trust"; } ];
      };
      "machines/high-trust/oauth2_proxy_key_file_2026-03-15" = {
        fields = [ "value" ];
        description = "oauth2-proxy session key file.";
        access = [ { type = "role"; value = "device_high_trust"; } ];
      };
      "machines/high-trust/openwebui_env_2026-03-15" = {
        fields = [ "value" ];
        description = "Open WebUI env file (WEBUI_SECRET_KEY + Zitadel OAuth creds).";
        access = [ { type = "role"; value = "device_high_trust"; } ];
      };
      "machines/high-trust/openrouter_2026-03-15" = {
        fields = [ "api-key" ];
        description = "OpenRouter API key.";
        access = [ { type = "role"; value = "device_high_trust"; } ];
      };
      "machines/high-trust/sabnzbd_api_key_2026-07-15" = {
        fields = [ "api-key" ];
        description = "Sabnzbd API key (nixarr).";
        access = [ { type = "role"; value = "device_high_trust"; } ];
      };
      "machines/high-trust/nzbgeek_api_key_2026-07-15" = {
        fields = [ "api-key" ];
        description = "NZBGeek API key (nixarr prowlarr).";
        access = [ { type = "role"; value = "device_high_trust"; } ];
      };

      # ── high-trust: per-host service secrets ──────────────────────
      "machines/high-trust/atuin-key-josh_2026-03-15" = {
        fields = [ "user" "password" "value" ];
        description = "Atuin sync key for josh (user/password/token).";
        access = [ { type = "role"; value = "device_high_trust"; } ];
      };
      "machines/high-trust/vaultwarden_env_2026-03-15" = {
        fields = [ "value" ];
        description = "Vaultwarden env file (bind-mounted into container).";
        access = [ { type = "role"; value = "device_high_trust"; } ];
      };

      # ── low-trust (gp3, joe, i001) ────────────────────────────────
      "machines/low-trust/headscale_auth_lowtrust_2026-03-15" = {
        fields = [ "value" ];
        description = "Headscale auth key for low-trust hosts.";
        access = [
          { type = "role"; value = "device_high_trust"; }
          { type = "role"; value = "device_low_trust"; }
        ];
      };

      # ── per-host: gp3 ─────────────────────────────────────────────
      "machines/by-host/gp3/hass_token" = {
        fields = [ "value" ];
        description = "Home Assistant long-lived token (gp3 battery manager).";
        access = [ { type = "sub"; value = "364267179626987523"; } ];
      };

      # ── per-host: h003 ────────────────────────────────────────────
      "machines/by-host/h003/hass_isp_speedtest_token" = {
        fields = [ "value" ];
        description = "Home Assistant long-lived token (h003 ISP speedtest).";
        access = [ { type = "sub"; value = "364267072236027907"; } ];
      };
    };
  };
}
