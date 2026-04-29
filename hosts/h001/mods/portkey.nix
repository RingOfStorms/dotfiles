{
  pkgs,
  constants,
  ...
}:
# Portkey AI Gateway (https://github.com/Portkey-AI/gateway) — bake-off
# candidate alongside litellm. OCI container (podman backend, set in
# containers/default.nix). Headless mode via FETCH_SETTINGS_FROM_FILE=true.
#
# OSS limitations to be aware of:
#  - No persistent cost tracking. Logs are in-memory + SSE only; the
#    "analytics" page on portkey.ai is hosted-SaaS / Enterprise.
#  - No GitHub Copilot provider (the `github` provider is GitHub Models
#    via Azure AI Inference, NOT Copilot).
#  - SSRF guard blocks non-loopback private-IP custom_host targets in OSS.
#    Reaching 100.64.0.8 (work air_prd) over tailscale falls outside the
#    default trusted set; we work around that with TRUSTED_CUSTOM_HOSTS,
#    which the OSS image does honor at request time (only the documented
#    enterprise allowlist is gated — env-var trust list works in OSS).
#
# Smoke-test scope mirrors bifrost.nix: OpenRouter + air_prd. No Copilot.
let
  c = constants.services.portkey;

  # Template for conf.json. @OPENROUTER_API_KEY@ is substituted at
  # activation time from the openbao-rendered env file.
  confTemplate = pkgs.writeText "portkey-conf.json.tmpl" (builtins.toJSON {
    plugins_enabled = [
      "default"
      "portkey"
    ];
    cache = false;
    integrations = [
      {
        provider = "openrouter";
        slug = "openrouter_main";
        credentials = {
          apiKey = "@OPENROUTER_API_KEY@";
        };
        models = [
          {
            slug = "*";
            status = "active";
            pricing_config = null;
          }
        ];
      }
      {
        # Upstream litellm (work air_prd). Treated as openai-compatible
        # via custom_host. The actual base URL is set per-request via
        # config / x-portkey-custom-host header; we still register the
        # integration so it shows up as a known virtual key.
        provider = "openai";
        slug = "air_prd";
        credentials = {
          apiKey = "na";
        };
        models = [
          {
            slug = "*";
            status = "active";
            pricing_config = null;
          }
        ];
      }
    ];
  });
in
{
  config = {
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];

    # State dir for the rendered conf.json. 0700/root because it embeds
    # the OPENROUTER_API_KEY plaintext. The container reads it as root.
    systemd.tmpfiles.rules = [
      "d ${c.dataDir} 0700 root root -"
    ];

    # Render conf.json from the template + secret env file. Runs as root
    # (oneshot) before the container starts.
    systemd.services.portkey-conf = {
      description = "Render Portkey conf.json from openbao secret";
      wantedBy = [ "podman-portkey.service" ];
      before = [ "podman-portkey.service" ];
      after = [ "openbao-secrets-ready.service" ];
      wants = [ "openbao-secrets-ready.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        # shellcheck disable=SC1091
        . /var/lib/openbao-secrets/litellm-env
        umask 077
        ${pkgs.gettext}/bin/envsubst '$OPENROUTER_API_KEY' \
          < ${confTemplate} > ${c.dataDir}/conf.json
        chmod 0600 ${c.dataDir}/conf.json
      '';
    };

    virtualisation.oci-containers.containers.portkey = {
      image = "portkeyai/gateway:1.15.2"; # pin, do not track :latest
      autoStart = true;
      ports = [ "${toString c.port}:8787" ];
      volumes = [
        "${c.dataDir}/conf.json:/app/conf.json:ro"
      ];
      environment = {
        FETCH_SETTINGS_FROM_FILE = "true";
        # Allow custom_host targets on the work tailnet (air_prd litellm).
        TRUSTED_CUSTOM_HOSTS = "100.64.0.8";
        # Disables the local /public/ console UI mount. Logs are
        # ephemeral anyway; no analytics value lost.
        NODE_ENV = "production";
      };
    };

    systemd.services.podman-portkey = {
      wants = [
        "network-online.target"
        "portkey-conf.service"
      ];
      after = [
        "network-online.target"
        "tailscaled.service"
        "portkey-conf.service"
      ];
    };
  };
}
