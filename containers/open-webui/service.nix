# Open WebUI (chat.joshuabell.xyz) on 127.0.0.1:8084. Talks to litellm
# (127.0.0.1:8094) and searx (127.0.0.1:8889), both host-network containers.
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
  routes.web = {
    port = 8084;
    name = "chat";
    exposure = "public";
    auth = "native-oidc";
    maxBody = "500m";
    extraConfig = "proxy_set_header X-Forwarded-Host $host;";
  };
}
