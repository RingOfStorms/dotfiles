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
        constants.services.minecraft.vanillaTestPort # Standalone vanilla test server
      ];

      # Reverse proxy for squaremap -- l001 terminates HTTPS and proxies
      # to h003 over tailscale. This nginx listens on the overlay IP only.
      services.nginx = {
        enable = true;

        # Drop everything by default
        virtualHosts."_" = {
          default = true;
          locations."/" = {
            return = "444";
          };
        };

        virtualHosts."computerboyz.joshuabell.xyz" = {
          listen = [{ addr = "${constants.host.overlayIp}"; port = 80; }];
          locations."/" = {
            return = "444";
          };
          locations."/map/survival/" = {
            proxyPass = "http://127.0.0.1:${toString constants.services.minecraft.mapPort}/";
            proxyWebsockets = true;
          };
        };
      };
      # Shell aliases for container management
      environment.shellAliases = {
        mc-attach = "sudo nixos-container run minecraft -- tmux attach -t mc";
      };
    }
  ];
}
