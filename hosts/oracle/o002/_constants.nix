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

  # The Tailscale IP of h001, used by nginx to proxy services. o002 only does
  # TLS termination + reverse proxy now; all stateful services (incl. the
  # migrated vaultwarden + atuin) live on h001 behind the tailnet.
  upstreamHost = "100.64.0.13";

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
