# Host-level support for floating containers on h003.
# The containers host module (inputs.containers.nixosModules.default) provides
# nginx with the runtime include dir, runtime firewall ports, extra-container
# and podman. Services themselves are deployed with `containers`,
# not by rebuilding this host. See containers/README.md.
{ ... }:
{
  ringofstorms.containers.nginx.enable = true;

  # Per-service nginx sites (written by `containers deploy`) listen on the
  # tailscale overlay IP, which only exists once tailscale has brought the
  # tailnet up and may not exist yet when nginx starts at boot. Ordering after
  # tailscaled-autoconnect is not enough (the address can come later), so allow
  # binding addresses not (yet) assigned to any interface.
  # (IPFreeBind is not a service directive; systemd ignores it.)
  boot.kernel.sysctl = {
    "net.ipv4.ip_nonlocal_bind" = 1;
    "net.ipv6.ip_nonlocal_bind" = 1;
  };
  systemd.services.nginx = {
    wants = [
      "network-online.target"
      "tailscaled-autoconnect.service"
    ];
    after = [
      "network-online.target"
      "tailscaled-autoconnect.service"
    ];
  };

  # Impermanent root: keep container data, runtime unit links, runtime
  # firewall ports/nginx includes and podman's image store across reboots.
  environment.persistence."/persist".directories = [
    "/srv/containers"
    "/etc/systemd-mutable"
    "/var/lib/fleet-containers"
    "/var/lib/containers"
    "/var/lib/nixos-containers"
    # extra-container <name>.conf links, read via EnvironmentFile by container@ units.
    "/etc/nixos-containers"
  ];
}
