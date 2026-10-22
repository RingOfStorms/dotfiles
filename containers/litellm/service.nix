# LiteLLM proxy on :8094, private network. open-webui uses it directly
# (net.uses litellm.web); other hosts go through the tailnet-only vhost
# https://litellm.joshuabell.xyz (tailnet DNS generated from this route on h005).
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

  # Tailnet-only (not proxied by o002); the internal server includes
  # nginx-acl-tailnet.conf from host-module.nix (ROUTING-PLAN §2.1). Streaming
  # completions: no proxy buffering, long timeouts.
  # Private network (ROUTING-PLAN §8 step 5): guest 10.233.7.2.
  net = {
    private = true;
    index = 7;
    # local model server on the LAN (api_base in container.nix)
    egress = [ "10.12.14.181:9010/tcp" ];
  };

  routes.web = {
    group = "AI";
    icon = "https://api.iconify.design/fluent-emoji-flat/locomotive.svg";
    port = 8094;
    exposure = "tailnet";
    auth = "native";
    buffering = false;
    timeouts = "600s";
    extraConfig = ''
      send_timeout 600s;
    '';
  };
}
