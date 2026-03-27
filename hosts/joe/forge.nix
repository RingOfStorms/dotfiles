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
  #
  # The ai-dock image's storage monitor watches storage/stable_diffusion/models/
  # and auto-symlinks files into Forge's actual model dirs. Place models here:
  #   checkpoints → /var/lib/forge/storage/stable_diffusion/models/ckpt/
  #   loras       → /var/lib/forge/storage/stable_diffusion/models/lora/
  #   vaes        → /var/lib/forge/storage/stable_diffusion/models/vae/
  #   controlnets → /var/lib/forge/storage/stable_diffusion/models/controlnet/
  #   upscalers   → /var/lib/forge/storage/stable_diffusion/models/esrgan/
  #   text enc.   → /var/lib/forge/storage/stable_diffusion/models/clip/
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
        SUPERVISOR_NO_AUTOSTART = "syncthing,jupyter,sshd,serviceportal";
        WEB_ENABLE_AUTH = "false";
        FORGE_ARGS = "--no-save-ui-config";
        WORKSPACE = "/workspace";
      };
      extraOptions = [
        "--device=nvidia.com/gpu=all"
      ];
    };
  };

  systemd.tmpfiles.rules =
    let
      sd = "${c.dataDir}/storage/stable_diffusion/models";
    in
    [
      "d ${c.dataDir} 0755 root root -"
      "d ${c.dataDir}/storage 0755 root root -"
      "d ${c.dataDir}/storage/stable_diffusion 0755 root root -"
      "d ${sd} 0755 root root -"
      "d ${sd}/ckpt 0755 root root -"
      "d ${sd}/lora 0755 root root -"
      "d ${sd}/vae 0755 root root -"
      "d ${sd}/controlnet 0755 root root -"
      "d ${sd}/esrgan 0755 root root -"
      "d ${sd}/clip 0755 root root -"
    ];

  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];
}
