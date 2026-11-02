# Puzzles server (puzzles.joshuabell.xyz), :8093 in its own netns (net.private).
{
  name = "puzzles";
  kind = "nixos";
  description = "Puzzles server (puzzles.joshuabell.xyz)";

  persist = {
    data = "/var/lib/puzzles-server"; # data.db, auxiliary.db, storage/
    nixos = "/var/lib/nixos";
  };

  # Host nginx proxies to the guest IP; no host port. index is fleet-wide
  # unique, never reuse.
  net = {
    private = true;
    index = 2;
  };
  # puzzles uses local auth only, no external APIs needed.
  internet = false;

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
