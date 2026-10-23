# h004 does not trust tailscale0 (ROUTING-PLAN §5.1). NFS is mounted over the
# LAN (h001 autofs -> 10.12.14.184) and opened to h001 only by nfs-data.nix; 22,
# 41641/udp and icmp are global too. Nothing is tailnet-only.
{ ... }:
{
  ringofstorms.tailnet.trustInterface = false;
}
