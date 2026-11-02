# h003 as a floating-container host, at parity with h001
# (hosts/h001/floating-containers.nix, containers/README.md).
# The containers host module (inputs.containers.nixosModules.default) provides
# nginx (:80/:443 internal, :8443 edge) with the runtime include dir, the
# nonlocal-bind sysctls and nginx's ordering after tailscale, the generated
# 80/443 firewall rules (sources from the `routes` inventory plus the runtime
# sets `cnt deploy` fills), the receiver for the cert h005 pushes to hosts with
# routes (hosts/h005/wildcard-cert.nix), runtime firewall ports,
# extra-container and podman, and (ringofstorms.containers.persist, on because
# ringofstorms.impermanence is) persistence of the container state dirs and
# the pushed cert. Services themselves are deployed with `containers`, not by
# rebuilding this host.
{ ... }:
{
  ringofstorms.containers = {
    enable = true;
    # LAN subnet for `exposure = "lan"` routes (nginx-acl-lan.conf).
    nginx.acl.lan = [ "10.12.14.0/24" ];
    privateNetwork.enable = true;
    # Shares h001's fleet repository; snapshots group by service tags, not
    # host. sec-agent.nix supplies environmentFile via configChanges.
    backup = {
      enable = true;
      schedule = "03:00";
    };
  };
}
