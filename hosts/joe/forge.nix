{
  constants,
  ...
}:
let
  name = "forge";
  c = constants.services.forge;
in
{
  # Stable Diffusion WebUI Forge with a simpler A1111-style UI.
  # Tailscale-only on joe for direct use; Open WebUI is intentionally not wired in.
  # Persistent data lives under /var/lib/forge, with models typically in:
  #   /var/lib/forge/storage/stable_diffusion/models/
  hardware.nvidia-container-toolkit.enable = true;

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers = {
    "${name}" = {
      image = "ghcr.io/ai-dock/stable-diffusion-webui-forge:latest-cuda";
      ports = [
        "0.0.0.0:${toString c.port}:7860"
      ];
      volumes = [
        "${c.dataDir}:/workspace"
      ];
      environment = {
        AUTO_UPDATE = "false";
        CF_QUICK_TUNNELS = "false";
        DIRECT_ADDRESS = constants.host.overlayIp;
        WEB_ENABLE_AUTH = "false";
        WORKSPACE = "/workspace";
      };
      extraOptions = [
        "--device=nvidia.com/gpu=all"
      ];
    };
  };

  systemd.tmpfiles.rules = [
    "d ${c.dataDir} 0755 root root -"
    "d ${c.dataDir}/storage 0755 root root -"
  ];

  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];
}
