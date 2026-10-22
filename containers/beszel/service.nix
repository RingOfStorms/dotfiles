# Beszel hub (monitoring), reached on h001's tailnet IP 100.64.0.13:8090
# (net.private: DNATed to the guest only for that address).
# Every agent's HUB_URL is http://100.64.0.13:8090 (flakes/beszel), so this
# stays pinned to h001 until the agents use a DNS name that follows the hub.
# Was hosts/h001/mods/monitoring_hub.nix on bare metal.
{
  name = "beszel";
  kind = "nixos";
  description = "Beszel monitoring hub (tailnet 100.64.0.13:8090)";
  host = "h001";

  # Private network (ROUTING-PLAN §8 step 5). The hub dials only agents
  # without a HUB_URL (hass); the rest connect in through the route.
  net = {
    private = true;
    index = 12;
    egress = [ "100.64.0.10:45876/tcp" ];
  };

  persist = {
    data = "/var/lib/beszel-hub"; # beszel_data/: data.db, auxiliary.db, id_ed25519 (agents trust its key)
    nixos = "/var/lib/nixos";
  };

  # Tailnet-only, no nginx vhost: agents and browsers hit the overlay IP
  # directly. The DNAT matches only daddr 100.64.0.13 (ports file), so the
  # LAN cannot reach it.
  routes.hub = {
    group = "Network";
    port = 8090;
    proto = "tcp";
    exposure = "tailnet";
    auth = "native";
  };
}
