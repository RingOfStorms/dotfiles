# Image generation API on joe's RTX 3080 (10 GB), replacing Forge.
#
# LocalAI: a prebuilt server with an OpenAI-compatible API
#   POST /v1/images/generations  {"model": "...", "prompt": "...", "size": "1024x1024"}
# plus a small web UI and model gallery at http://joe:8080/. Open WebUI
# (Settings > Images > OpenAI, base http://joe:8080/v1) and coding agents
# use the same endpoint. Backends (stable-diffusion.cpp, diffusers) are
# downloaded on first use into the `backends` dir; models go in `models`.
#
# Models that fit 10 GB (install from the UI gallery or `local-ai models install`):
#   flux.1-dev-ggml (12B, quantized, clip on CPU), flux.1-schnell,
#   flux.2-klein-4b (fast, also edits). Not z-image-turbo: bf16 6B, ~12 GB, OOMs.
# See README.md for what was kept from Forge.
{
  name = "image-gen";
  kind = "podman";
  description = "LocalAI image generation API (GPU)";
  host = "joe";

  persist = {
    models = "/models";
    backends = "/backends";
    configuration = "/configuration";
    data = "/data";
    images = "/tmp/generated";
  };

  # http://joe:8080/v1/images/generations
  tcpPorts = [ 8080 ];
  podman = {
    image = "docker.io/localai/localai:v4.11.0-gpu-nvidia-cuda-12";
    ports = [ "0.0.0.0:8080:8080" ];
    environment = {
      MODELS_PATH = "/models";
      LOCALAI_BACKENDS_PATH = "/backends";
      LOCALAI_GENERATED_CONTENT_PATH = "/tmp/generated";
      # One model in VRAM at a time; unload after 15 min idle so the GPU is
      # free for games and Kokoro.
      LOCALAI_SINGLE_ACTIVE_BACKEND = "true";
      LOCALAI_WATCHDOG_IDLE = "true";
      LOCALAI_WATCHDOG_IDLE_TIMEOUT = "15m";
    };
    extraArgs = [ "--device=nvidia.com/gpu=all" ];
  };
}
