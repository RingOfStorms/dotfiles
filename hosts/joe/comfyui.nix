# ComfyUI — GPU-accelerated image generation server (FLUX, SD, etc.)
# Runs as a Podman OCI container with NVIDIA CDI passthrough to the RTX 3090.
# Accessible over Tailscale for Open WebUI integration (h001) and direct workflow editing.
#
# After first deploy:
#   1. Open http://100.64.0.12:8188 via Tailscale
#   2. Use ComfyUI-Manager to download FLUX models:
#      - FLUX.1 schnell (fast, 4-step, Apache 2.0)
#      - FLUX.1 dev (high quality, 20-50 step, non-commercial)
#      - Supporting models: clip_l, t5xxl_fp8, ae (FLUX VAE)
#   3. Open WebUI will auto-discover available models from ComfyUI
{
  constants,
  ...
}:
let
  name = "comfyui";
  c = constants.services.comfyui;
in
{
  virtualisation.oci-containers.containers = {
    "${name}" = {
      image = "yanwk/comfyui-boot:cu128-slim";
      ports = [
        "0.0.0.0:${toString c.port}:8188"
      ];
      volumes = [
        # Persist everything: models, custom nodes, outputs, config
        "${c.dataDir}:/root"
      ];
      environment = {
        # Listen on all interfaces inside the container
        CLI_ARGS = "--listen 0.0.0.0 --port 8188";
      };
      extraOptions = [
        # Pass all NVIDIA GPUs into the container via CDI
        "--device=nvidia.com/gpu=all"
        "--group-add=video"
      ];
    };
  };

  # Create data directory before the container starts
  system.activationScripts."${name}_directories" = ''
    mkdir -p ${c.dataDir}
  '';

  # Allow access from Tailscale overlay only (not exposed on LAN)
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];
}
