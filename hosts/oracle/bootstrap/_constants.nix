# Constants for the Oracle bootstrap template.
#
# This is a REUSABLE TEMPLATE. When provisioning a real Oracle host, copy
# hosts/oracle/bootstrap -> hosts/oracle/<name>/ and edit:
#   - host.name        (e.g. "o002")
#   - host.overlayIp   (tailnet IP, assigned after first join)
#   - host.publicIp    (Oracle-assigned public IP)
#   - the disk UUIDs in flake.nix's ringofstorms.impermanence (after the
#     disko partition step prints them via `lsblk -o name,uuid`)
{
  host = {
    name = "bootstrap";
    primaryUser = "root";
    stateVersion = "26.05";
    # overlayIp / publicIp filled in per concrete host.
  };
}
