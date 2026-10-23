# Puzzles server (puzzles.joshuabell.xyz), :8093 in its own netns (net.private).
# Was hosts/h001/mods/puzzles.nix on bare metal.
{
  name = "puzzles";
  kind = "nixos";
  description = "Puzzles server (puzzles.joshuabell.xyz)";
  host = "h001";

  persist = {
    data = "/var/lib/puzzles-server"; # data.db, auxiliary.db, storage/
    nixos = "/var/lib/nixos";
  };

  # Private network (ROUTING-PLAN §8 step 5): guest 10.233.2.2, host nginx
  # proxies there; no host port. index is fleet-wide unique, never reuse.
  net = {
    private = true;
    index = 2;
  };
  # Finding M2: puzzles uses local auth only, no external APIs needed.
  internet = false;

  # maxBody 500m = h001's http-level client_max_body_size, which the old
  # vhost (no own limit) inherited.
  routes.web = {
    group = "Personal";
    icon = "https://api.iconify.design/fluent-emoji-flat/puzzle-piece.svg";
    port = 8093;
    exposure = "public";
    auth = "native";
    maxBody = "500m";
    extraConfig = "proxy_set_header X-Forwarded-Host $host;";
  };
}
