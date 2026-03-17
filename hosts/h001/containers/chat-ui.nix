{
  constants,
  config,
  lib,
  ...
}:
let
  name = "chat-ui";
  c = constants.services.chatUi;
  litellm = constants.services.litellm;
  zitadel = constants.services.zitadel;
  hostDataDir = c.dataDir;

  v_port = c.port;

  # chat-ui-db image bundles MongoDB inside the container
  image = "ghcr.io/huggingface/chat-ui-db:latest";

  baoSecrets = config.ringofstorms.secretsBao.secrets or {};
  hasChatUiEnv = baoSecrets ? "chatui_env_2026-03-17";
in
{
  virtualisation.oci-containers.containers = {
    "${name}" = {
      inherit image;
      ports = [
        "127.0.0.1:${toString v_port}:3000"
      ];
      volumes = [
        "${hostDataDir}/db:/data/db"
      ];
      environment = {
        # Connect to litellm proxy on the host
        OPENAI_BASE_URL = "http://host.containers.internal:${toString litellm.port}/v1";
        OPENAI_API_KEY = "na";

        # App settings
        PUBLIC_APP_NAME = "Josh AI";
        PUBLIC_APP_DESCRIPTION = "Chat with AI models";

        # Body size limit for file uploads (2GB)
        BODY_SIZE_LIMIT = "2147483648";
      };
      extraOptions = [
        # Allow the container to reach host services (litellm, etc.)
        "--add-host=host.containers.internal:host-gateway"
      ]
      # Inject OIDC secrets env file when available from OpenBao
      # Secret should contain: OPENID_CONFIG, OPENID_CLIENT_ID, OPENID_CLIENT_SECRET, OPENID_SCOPES
      ++ lib.optionals hasChatUiEnv [
        "--env-file=${baoSecrets."chatui_env_2026-03-17".path}"
      ];
    };
  };

  system.activationScripts."${name}_directories" = ''
    mkdir -p ${hostDataDir}/db
    chown 1000:1000 ${hostDataDir}/db
    chmod 755 ${hostDataDir}/db
  '';

  services.nginx.virtualHosts."${c.domain}" = {
    addSSL = true;
    sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
    sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
    locations = {
      "/" = {
        proxyWebsockets = true;
        proxyPass = "http://127.0.0.1:${builtins.toString v_port}";
        extraConfig = ''
          proxy_set_header X-Forwarded-Proto https;
        '';
      };
    };
  };
}
