# Open WebUI (chat.joshuabell.xyz) on :8084, private network. Talks to litellm
# (10.233.7.2:8094) and searx (10.233.8.2:8889) directly (net.uses).
# Was hosts/h001/mods/openwebui.nix on bare metal.
{
  name = "open-webui";
  kind = "nixos";
  description = "Open WebUI (chat.joshuabell.xyz)";
  host = "h001";

  persist = {
    data = "/var/lib/private/open-webui"; # DynamicUser state (webui.db, uploads, vector db)
    nixos = "/var/lib/nixos";
  };

  # maxBody 500m = h001's http-level client_max_body_size, which the old
  # vhost (no own limit) inherited.
  # Private network (ROUTING-PLAN §8 step 5): guest 10.233.6.2.
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
}
