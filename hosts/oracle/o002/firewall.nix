# o002 does not trust tailscale0 (ROUTING-PLAN §5.1). Everything it serves is
# public and opened globally: 80/443/3032 (nginx.nix), 3478/udp DERP STUN
# (headscale.nix), 22. headscale itself listens on 127.0.0.1 behind nginx.
# o002 only initiates connections to service hosts' edge listeners.
#
# ROUTING-PLAN §8 step 2 explicit exception: o002's global :22 is kept as a
# deliberate break-glass path (it is the public edge, has no LAN, and is the
# one host every other host's ssh rule always excludes from its high-trust
# tailnet allow). Every other host scopes ssh; o002 does not.
{ ... }:
{
  ringofstorms.tailnet.trustInterface = false;
}
