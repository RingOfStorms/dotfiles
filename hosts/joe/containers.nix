# Host support for floating containers on joe (GPU services, podman kind).
# Services are deployed with `cnt deploy <svc>`, not by rebuilding joe.
# See containers/README.md.
{ ... }:
{
  # NVIDIA CDI spec (/var/run/cdi) so podman can use --device=nvidia.com/gpu=all.
  hardware.nvidia-container-toolkit.enable = true;

  # Checked by `containers deploy/move` against service.nix `requires`.
  ringofstorms.containers.capabilities = [
    "nvidia" # RTX 3080, CDI device nvidia.com/gpu (toolkit above)
  ];

  # joe has an impermanent root: keep container data, runtime unit links,
  # runtime firewall ports and podman's image store across reboots.
  environment.persistence."/persist".directories = [
    "/srv/containers"
    "/etc/systemd-mutable"
    "/var/lib/fleet-containers"
    "/var/lib/containers"
  ];
}
