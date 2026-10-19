# Beszel hub (monitoring) on h001's tailnet IP, 100.64.0.13:8090.
# Every agent's HUB_URL is http://100.64.0.13:8090 (flakes/beszel), so this
# stays pinned to h001 until the agents use a DNS name that follows the hub.
# Was hosts/h001/mods/monitoring_hub.nix on bare metal.
{
  name = "beszel";
  kind = "nixos";
  description = "Beszel monitoring hub (tailnet 100.64.0.13:8090)";
  host = "h001";

  persist = {
    data = "/var/lib/beszel-hub"; # beszel_data/: data.db, auxiliary.db, id_ed25519 (agents trust its key)
    nixos = "/var/lib/nixos";
  };

  # Tailnet-only, no nginx vhost: agents and browsers hit the overlay IP
  # directly. The socket exists only on 100.64.0.13, so the ports-file
  # entry this adds cannot expose it on the LAN.
  routes.hub = {
    port = 8090;
    proto = "tcp";
    exposure = "tailnet";
    auth = "native";
  };
}
