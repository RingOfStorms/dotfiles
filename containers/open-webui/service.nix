# Open WebUI (chat.joshuabell.xyz) on :8084, private network. Talks to litellm
# (10.233.7.2:8094) and searx (10.233.8.2:8889) directly (net.uses).
{
  name = "open-webui";
  kind = "nixos";
  description = "Open WebUI (chat.joshuabell.xyz)";

  persist = {
    data = "/var/lib/private/open-webui"; # DynamicUser state (webui.db, uploads, vector db)
    nixos = "/var/lib/nixos";
  };

  # sec-agent grant on the host (bound read-only in flake.nix); cnt deploy
  # and cnt move refuse a target host that lacks it.
  secrets = [ "openwebui_env_2026-03-15" ];

  net = {
    private = true;
    index = 6;
    uses = [
      "litellm.web"
      "searx.api"
      "zitadel.web" # OIDC discovery/token (sso)
    ];
  };

  routes.web = {
    group = "AI";
    port = 8084;
    name = "chat";
    exposure = "public";
    auth = "native-oidc";
    maxBody = "500m";
    extraConfig = "proxy_set_header X-Forwarded-Host $host;";
  };
  # re-downloadable model caches
  backup.exclude = [
    "data/hf_home"
    "data/transformers_home"
    "data/xet"
    "data/models--*"
  ];
}
