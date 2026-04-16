# Firewall rules for imperative extra-container services.
#
# These containers are NOT managed by nixos-rebuild. They are created and
# updated independently via `extra-container` (see flakes/containers/).
# This module only opens the host firewall ports they need.
{ constants, ... }:
{
  networking.firewall.allowedTCPPorts = [
    constants.services.minecraft.port # Velocity proxy (player-facing)
  ];
}
