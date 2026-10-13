# LiteLLM proxy on 0.0.0.0:8094 (host network). Used by open-webui over
# loopback and by other hosts over the tailnet (no vhost).
# Was hosts/h001/mods/litellm.nix on bare metal.
#
# The port is NOT in tcpPorts (that would open it on every interface); h001's
# firewall keeps it open on tailscale0 only (hosts/h001 networking.firewall).
{
  name = "litellm";
  kind = "nixos";
  description = "LiteLLM proxy (tailnet :8094)";
  host = "h001";

  persist = {
    # DynamicUser state: github_copilot token dir, .config, caches.
    data = "/var/lib/private/litellm";
    nixos = "/var/lib/nixos";
  };
}
