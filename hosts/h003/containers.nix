# Host-level support for floating containers on h003.
# The containers host module (inputs.containers.nixosModules.default) provides
# nginx with the runtime include dir, runtime firewall ports, extra-container
# and podman. Services themselves are deployed with `containers`,
# not by rebuilding this host. See containers/README.md.
{ ... }:
{
  ringofstorms.containers.nginx.enable = true;

  # Per-service nginx sites (written by `containers deploy`) listen on the
  # tailscale overlay IP. Wait for tailscale to have its address;
  # IPFreeBind lets nginx bind even if it races.
  systemd.services.nginx = {
    wants = [
      "network-online.target"
      "tailscaled-autoconnect.service"
    ];
    after = [
      "network-online.target"
      "tailscaled-autoconnect.service"
    ];
    serviceConfig.IPFreeBind = true;
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
