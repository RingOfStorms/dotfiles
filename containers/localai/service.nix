# LocalAI on joe's RTX 3080 (10 GB): image generation, TTS, text chat and 3D.
#
# LocalAI: a prebuilt server with an OpenAI-compatible API
#   POST /v1/images/generations  {"model": "...", "prompt": "...", "size": "1024x1024"}
# plus a small web UI and model gallery at http://joe:8080/. Open WebUI
# (Settings > Images > OpenAI, base http://joe:8080/v1) and coding agents
# use the same endpoint. Backends (stable-diffusion.cpp, diffusers, ...) are
# downloaded on first use into the `backends` dir; models go in `models`.
#
# Models are installed from the UI gallery or with
# `podman exec localai /local-ai models install <name>`. Fit on 10 GB is the
# constraint: quantized/GGUF weights work, full-size bf16 diffusers pipelines
# OOM, and the KV cache can be quantized or the context shortened to make a
# chat model fit. See README.md.
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

  # https://localai.joshuabell.xyz/v1/images/generations (tailnet route; DNS
  # points at joe's overlay IP). joe's own nginx terminates TLS with the
  # zone wildcard pushed from h005 (hosts/h005/wildcard-cert.nix) and
  # proxies to 127.0.0.1:8080.
  # auth = "none": LocalAI has no login (only an optional API_KEY, which
  # would break the existing Open WebUI / agent clients). M6: instead of the
  # whole tailnet, joe's vhost only admits the known callers (allow -> nginx
  # allow <overlayIp>; deny all): h001 (Open WebUI and net.uses callers such
  # as life, masqueraded to h001's overlay IP) and the high-trust
  # workstations running coding agents. Low-trust hosts (joe, i001), o002
  # and phones/unlisted nodes get 403.
  routes.web = {
    group = "AI";
    icon = "https://api.iconify.design/fluent-emoji-flat/llama.svg";
    port = 8080;
    exposure = "tailnet";
    auth = "none";
    allow = [
      "h001"
      "lio"
      "oren"
      "juni"
      "gp3"
    ];
    # Image generation can take minutes; uploads are small.
    timeouts = "600s";
  };

  # No tcpPorts: published on loopback only; joe's nginx is the way in.
  podman = {
    image = "docker.io/localai/localai:v4.11.0-gpu-nvidia-cuda-12@sha256:1ee31dce19426ce7948e003bd2143bc88289db984369bdc53179c184d5ad07f9";
    # Loopback only: reached through joe's nginx (:443), never directly.
    ports = [ "127.0.0.1:8080:8080" ];
    environment = {
      MODELS_PATH = "/models";
      LOCALAI_BACKENDS_PATH = "/backends";
      LOCALAI_GENERATED_CONTENT_PATH = "/tmp/generated";
      # One model in VRAM at a time; unload after 15 min idle so the GPU is
      # free for games and other work.
      LOCALAI_SINGLE_ACTIVE_BACKEND = "true";
      LOCALAI_WATCHDOG_IDLE = "true";
      LOCALAI_WATCHDOG_IDLE_TIMEOUT = "15m";
    };
    extraArgs = [ "--device=nvidia.com/gpu=all" ];
  };
}
