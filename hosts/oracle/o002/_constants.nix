# Constants for o002 (Oracle Ampere aarch64 cloud gateway, rebuild of o001).
# Derived from hosts/oracle/bootstrap. overlayIp is assigned after the
# first tailnet join.
{
  host = {
    name = "o002";
    primaryUser = "root";
    stateVersion = "26.05";
    publicIp = "147.224.160.25";
    # overlayIp filled in after first tailnet join.
  };
}
