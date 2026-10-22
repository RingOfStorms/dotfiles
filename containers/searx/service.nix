# SearXNG, private backend for Open WebUI web search (10.233.8.2:8889, private network).
# Was hosts/h001/mods/searx.nix on bare metal. No vhost, no open ports.
{
  name = "searx";
  kind = "nixos";
  description = "SearXNG metasearch (private, used by open-webui)";
  host = "h001";

  persist = {
    data = "/var/lib/searx"; # secret-key.env
    nixos = "/var/lib/nixos";
  };

  # Private network (ROUTING-PLAN §8 step 5): guest 10.233.8.2, reached
  # only by open-webui (net.uses searx.api) over the guest IP.
  net = {
    private = true;
    index = 8;
  };
  routes.api = {
    port = 8889;
    exposure = "local";
  };
}
