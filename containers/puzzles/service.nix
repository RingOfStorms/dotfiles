# Puzzles server (puzzles.joshuabell.xyz), 127.0.0.1:8093.
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
