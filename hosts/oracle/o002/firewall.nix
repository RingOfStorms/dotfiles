# Public SSH is a deliberate break-glass path: the edge has no LAN and is
# excluded from other hosts' high-trust SSH allowlists. It reaches service
# hosts only through their edge listeners.
{ ... }:
{
  ringofstorms.tailnet.trustInterface = false;
}
