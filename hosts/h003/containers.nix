# h003 as a floating-container host, at parity with h001
# (hosts/h001/floating-containers.nix, containers/README.md).
# The containers host module (inputs.containers.nixosModules.default) provides
# nginx with the runtime include dir, the nonlocal-bind sysctls and nginx's
# ordering after tailscale, 80/443 in the firewall, runtime firewall ports,
# extra-container and podman, and (ringofstorms.containers.persist, on because
# ringofstorms.impermanence is) persistence of the container state dirs.
# Services themselves are deployed with `containers`, not by rebuilding this
# host.
{ ... }:
{
  # Impermanent root: keep the pushed wildcard (wildcard-cert-receiver.nix)
  # across reboots so nginx has a certificate before h005 pushes again.
  environment.persistence."/persist".directories = [ "/var/lib/fleet-cert" ];

  ringofstorms.containers = {
    enable = true;
    # Runtime vhosts from service.nix `nginx` blocks.
    nginx.enable = true;
    # o002 proxies public routes to the :8443 edge listener; drop it on the
    # internal :80/:443 listener (ROUTING-PLAN §2.3.1).
    nginx.edge.blockInternal = true;
    # LAN subnet for `exposure = "lan"` routes (nginx-acl-lan.conf).
    nginx.acl.lan = [ "10.12.14.0/24" ];
    # Internal :443 listeners use the wildcard pushed by h005
    # (hosts/wildcard-cert-receiver.nix). h005's wildcard-cert.nix must list
    # h003 as a push target (with its pinned host key) before this exists.
    nginx.tls.certDir = "/var/lib/fleet-cert/joshuabell.xyz/current";
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
