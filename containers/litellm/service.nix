# LiteLLM proxy on 127.0.0.1:8094 (host network). open-webui uses it over
# loopback; other hosts go through the tailnet-only vhost
# https://litellm.joshuabell.xyz (the name is in fleet.nix h001Subdomains).
# Was hosts/h001/mods/litellm.nix on bare metal.
{
  name = "litellm";
  kind = "nixos";
  description = "LiteLLM proxy (tailnet, litellm.joshuabell.xyz)";
  host = "h001";

  persist = {
    # DynamicUser state: github_copilot token dir, .config, caches.
    data = "/var/lib/private/litellm";
    nixos = "/var/lib/nixos";
  };

  # Tailnet-only (not proxied by o002); the allow/deny keeps that enforced in
  # nginx until the internal listener split (ROUTING-PLAN §2.3). Streaming
  # completions: no proxy buffering, long timeouts.
  routes.web = {
    port = 8094;
    exposure = "tailnet";
    auth = "native";
    buffering = false;
    timeouts = "600s";
    extraConfig = ''
      send_timeout 600s;
      allow 100.64.0.0/10;
      allow 127.0.0.0/8;
      deny all;
    '';
  };
}
