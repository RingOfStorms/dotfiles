# LiteLLM proxy on :8094, private network. open-webui uses it directly
# (net.uses litellm.web); other hosts go through the tailnet-only vhost
# https://litellm.joshuabell.xyz (tailnet DNS generated from this route on h005).
{
  name = "litellm";
  kind = "nixos";
  description = "LiteLLM proxy (tailnet, litellm.joshuabell.xyz)";

  persist = {
    # DynamicUser state: github_copilot token dir, .config, caches.
    data = "/var/lib/private/litellm";
    nixos = "/var/lib/nixos";
  };

  # sec-agent grant on the host (bound read-only in flake.nix); cnt deploy
  # and cnt move refuse a target host that lacks it.
  secrets = [ "litellm-env" ];

  net = {
    private = true;
    index = 7;
    # local model server on the LAN (api_base in container.nix)
    egress = [ "10.12.14.181:9010/tcp" ];
  };

  # Streaming completions: no proxy buffering, long timeouts.
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
