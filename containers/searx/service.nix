# SearXNG, private backend for Open WebUI web search (10.233.8.2:8889, private network).
# No vhost, no open ports.
{
  name = "searx";
  kind = "nixos";
  description = "SearXNG metasearch (private, used by open-webui)";

  persist = {
    data = "/var/lib/searx"; # secret-key.env
    nixos = "/var/lib/nixos";
  };

  # Reached only by open-webui (net.uses searx.api) over the guest IP.
  net = {
    private = true;
    index = 8;
  };
  routes.api = {
    port = 8889;
    exposure = "local";
  };
}
