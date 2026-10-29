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
    # Host side for service.nix net.private (ROUTING-PLAN §8 step 5).
    privateNetwork.enable = true;
    # Nightly restic of every service here, one snapshot per svc:<name>
    # (ROUTING-PLAN §9.1). Credentials: restic_h001_env_2026-10-01 (shared
    # fleet repo; snapshots group by svc tags, not host), wired in
    # sec-agent.nix via configChanges.
    backup = {
      enable = true;
      schedule = "03:00";
    };
  };
}
