{
  constants,
  ...
}:
let
  name = "kokoro-tts";
  c = constants.services.kokoro-tts;
in
{
  # ── NVIDIA Container Toolkit (CDI) for GPU passthrough to Podman ──────────
  hardware.nvidia-container-toolkit.enable = true;

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers = {
    "${name}" = {
      image = "ghcr.io/remsky/kokoro-fastapi-gpu:v0.2.4-master";
      ports = [
        "0.0.0.0:${toString c.port}:8880"
      ];
      volumes = [
        # Persist downloaded models across reboots
        "${c.dataDir}/models:/app/api/src/models"
        # Custom voice packs (.pt files) — drop files here and they become available
        "${c.dataDir}/voices:/app/api/src/voices/custom"
      ];
      environment = {
        USE_GPU = "true";
        PYTHONUNBUFFERED = "1";
        # Allow external access (CORS)
        ALLOW_ORIGINS = "*";
      };
      extraOptions = [
        # Pass all NVIDIA GPUs into the container via CDI
        "--device=nvidia.com/gpu=all"
        "--group-add=video"
      ];
    };
  };

  # Create data directories before the container starts
  system.activationScripts."${name}_directories" = ''
    mkdir -p ${c.dataDir}/models
    mkdir -p ${c.dataDir}/voices
  '';

  # Allow access from Tailscale overlay and LAN
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];
  networking.firewall.allowedTCPPorts = [ c.port ];
}
