# o002 does not trust tailscale0 (ROUTING-PLAN §5.1). Everything it serves is
# public and opened globally: 80/443/3032 (nginx.nix), 3478/udp DERP STUN
# (headscale.nix), 22. headscale itself listens on 127.0.0.1 behind nginx.
# o002 only initiates connections to service hosts' edge listeners.
{ ... }:
{
  ringofstorms.tailnet.trustInterface = false;
}
