# These are host level options required for containers we are running on this host.
# We're purposfully mixing imperative containers in on this host for ease of deploying
# those individual containers.
{ constants, lib, ... }:
{
  config = lib.mkMerge [
    # ── Minecraft (Velocity + 2x Paper) ─────────────────────────────────
    # Start: nix run ./flakes/containers/minecraft -- create --start
    # Stop:  nix run ./flakes/containers/minecraft -- destroy
    {
      networking.firewall.allowedTCPPorts = [
        constants.services.minecraft.port # Velocity proxy (player-facing)
        80 # squaremap web UI (nginx reverse proxy)
      ];

      # squaremap web UI -- reverse proxy from port 80 to the container's map port
      services.nginx = {
        enable = true;
        virtualHosts."_" = {
          listen = [{ addr = "0.0.0.0"; port = 80; }];
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString constants.services.minecraft.mapPort}";
            proxyWebsockets = true;
          };
        };
      };
    }
  ];
}
