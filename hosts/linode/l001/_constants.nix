# Service constants for l001 (Linode - Headscale)
# Single source of truth for ports, data paths, and domains.
{
  host = {
    name = "l001";
    primaryUser = "root";
    stateVersion = "24.11";
    domain = "joshuabell.xyz";
    acmeEmail = "admin@joshuabell.xyz";
  };

  services = {
    headscale = {
      port = 8080;
      dataDir = "/var/lib/headscale";
      domain = "headscale.joshuabell.xyz";
      baseDomain = "net.joshuabell.xyz";
    };
  };
}
