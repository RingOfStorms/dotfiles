# LocalAI on joe's RTX 3080 (10 GB): image generation + Kokoro TTS.
#
# LocalAI: a prebuilt server with an OpenAI-compatible API
#   POST /v1/images/generations  {"model": "...", "prompt": "...", "size": "1024x1024"}
# plus a small web UI and model gallery at http://joe:8080/. Open WebUI
# (Settings > Images > OpenAI, base http://joe:8080/v1) and coding agents
# use the same endpoint. Backends (stable-diffusion.cpp, diffusers) are
# downloaded on first use into the `backends` dir; models go in `models`.
#
# Models that fit 10 GB (install from the UI gallery or `podman exec localai /local-ai models install`):
#   flux.2-klein-4b (tested), flux.1-dev-ggml. Not z-image-turbo or
#   flux.1-schnell (full diffusers weights, OOM). See README.md.
{
  name = "localai";
  kind = "podman";
  description = "LocalAI image generation API (GPU)";
  host = "joe";
  # --device=nvidia.com/gpu=all below needs the CDI spec on the host.
  requires = [ "nvidia" ];

  persist = {
    models = "/models";
    backends = "/backends";
    configuration = "/configuration";
    data = "/data";
    images = "/tmp/generated";
  };

  # Set false once models/backends are installed: no outbound network at
  # all (gallery installs and backend downloads then fail). Ports still work.
  internet = false;

  # https://localai.ts.joshuabell.xyz/v1/images/generations (private zone,
  # tailnet-only DNS). h005's nginx terminates TLS with *.ts.joshuabell.xyz
  # and proxies to joe's overlay IP:8080 (hosts/h005/private-zone.nix).
  # auth = "none": LocalAI has no login (only an optional API_KEY, which
  # would break the existing Open WebUI / agent clients); the tailnet is the
  # boundary, same as the raw port before this route.
  routes.web = {
    port = 8080;
    zone = "private";
    exposure = "tailnet";
    auth = "none";
    # Image generation can take minutes; uploads are small.
    timeouts = "600s";
  };

  # Still opened for http://joe:8080 and for h005's proxy (bound to the
  # overlay IP only, below).
  tcpPorts = [ 8080 ];
  podman = {
    image = "docker.io/localai/localai:v4.11.0-gpu-nvidia-cuda-12";
    # Tailnet only (joe overlay IP); not reachable from the LAN.
    ports = [ "100.64.0.12:8080:8080" ];
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
