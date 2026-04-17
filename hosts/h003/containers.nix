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
      ];
    }
  ];
}
