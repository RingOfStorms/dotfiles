# Constants for o002 (Oracle Ampere aarch64 cloud gateway, rebuild of o001).
# Derived from hosts/oracle/bootstrap. overlayIp is assigned after the
# first tailnet join.
{
  host = {
    name = "o002";
    primaryUser = "root";
    stateVersion = "26.05";
    publicIp = "164.152.19.60";
    overlayIp = "100.64.0.5";
  };

  services = {
    # Headscale coordination server, migrated off l001. Co-hosted with
    # tailscaled (see headscale.nix for the co-host mitigations).
    headscale = {
      port = 8080;
      dataDir = "/var/lib/headscale";
      domain = "headscale.joshuabell.xyz";
      baseDomain = "net.joshuabell.xyz";
    };
  };
}
