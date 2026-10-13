# SearXNG, private backend for Open WebUI web search (127.0.0.1:8889).
# Was hosts/h001/mods/searx.nix on bare metal. No vhost, no open ports.
{
  name = "searx";
  kind = "nixos";
  description = "SearXNG metasearch (loopback only, used by open-webui)";
  host = "h001";

  persist = {
    data = "/var/lib/searx"; # secret-key.env
    nixos = "/var/lib/nixos";
  };
}
