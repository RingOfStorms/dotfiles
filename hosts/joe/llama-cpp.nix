{
  inputs,
  constants,
  pkgs,
  lib,
  ...
}:
let
  c = constants.services.llama-cpp;

  # Pinned llama-cpp from a frozen nixpkgs (see hosts/joe/flake.nix input).
  # We import the pinned nixpkgs as its own pkgs set with cudaSupport=true so
  # the resulting llama-cpp derivation hash exactly matches the one already
  # in /nix/store on joe, avoiding a multi-hour from-source CUDA rebuild
  # (which has been crashing the machine). Bumping
  # inputs.llama-cpp-nixpkgs is what triggers a rebuild -- nothing else does.
  pkgsLlamaCpp = import inputs.llama-cpp-nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    config = {
      allowUnfree = true;
      cudaSupport = true;
    };
  };
in
{
  # Enable CUDA globally on this host so any other package that wants CUDA
  # picks it up. The llama-cpp package itself comes from the pinned pkgs
  # set above, NOT from this host's rolling pkgs, so this flag does not
  # affect llama-cpp's drv hash.
  nixpkgs.config.cudaSupport = true;

  services.llama-cpp = {
    enable = true;
    package = pkgsLlamaCpp.llama-cpp;
    host = "0.0.0.0";
    port = c.port;

    # Router-mode model presets.
    # Models are downloaded from Hugging Face on first request and cached in
    # /var/cache/llama-cpp (LLAMA_CACHE). The router loads/unloads models
    # on demand, capped by --models-max below (mirrors the old
    # OLLAMA_KEEP_ALIVE=0 behavior on a single 24GB GPU).
    # Model picks driven by the r/LocalLLaMA "Best Local LLMs Apr 2026"
    # megathread, filtered to what fits joe (RTX 3080 10GB + 32GB DDR4):
    #
    #   * Gemma 4 26B-A4B (MoE, 4B activated, multimodal) — the most-
    #     recommended general-purpose model in the thread. ~16GB on disk
    #     at UD-Q4_K_XL, very fast (~100+ t/s reported), comfy on 32GB RAM.
    #     Daily driver / vision / chat.
    #
    #   * Qwen3.5-35B-A3B (MoE, 3B activated) — u/awitod's go-to agentic
    #     coding model; u/youcloudsofdoom runs the same quant on an 8GB
    #     laptop 4070 + 64GB DDR5 at ~30 t/s. Tight on 32GB but workable
    #     with --n-cpu-moe (most expert weights live in RAM, only the
    #     active 3B + KV cache need to be hot on the GPU).
    modelsPreset = {
      # Primary: Gemma 4 26B-A4B (general purpose, multimodal).
      "gemma-4-26b-a4b" = {
        hf-repo = "unsloth/gemma-4-26B-A4B-it-GGUF";
        hf-file = "gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf";
        alias = "gemma-4-26b-a4b";
        ngl = "auto";
        ctx-size = "65536";
        flash-attn = "auto";
        jinja = "on";
        # Sampling per Gemma 4 model card (thread: false79, truthputer).
        temp = "1.0";
        top-p = "0.95";
        top-k = "64";
        # Default thinking ON at the model level; litellm flips it per
        # request via chat_template_kwargs.enable_thinking, so the
        # `-no_think` model variant overrides this to false per-call.
        chat-template-kwargs = ''{"enable_thinking":true}'';
      };

      # Secondary: Qwen3.5-35B-A3B (agentic coding).
      "qwen3.5-35b-a3b" = {
        hf-repo = "unsloth/Qwen3.5-35B-A3B-GGUF";
        hf-file = "Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf";
        alias = "qwen3.5-35b-a3b";
        ngl = "auto";
        ctx-size = "65536";
        flash-attn = "auto";
        jinja = "on";
        # Offload most MoE expert tensors to CPU — we only have 10GB VRAM,
        # but with 3B active params per token the GPU still does the hot
        # work. Tune down if RAM pressure gets ugly.
        n-cpu-moe = "32";
        # Sampling per u/awitod's Qwen3.5-35B-A3B unsloth-guide config.
        temp = "0.7";
        top-p = "0.8";
        top-k = "20";
        min-p = "0.0";
        presence-penalty = "1.5";
      };
    };

    extraFlags = [
      "--models-max"
      "1" # Single 3090 — keep at most one model resident at a time.
      "--metrics" # Prometheus-compatible /metrics endpoint.
    ];
  };

  # The upstream services.llama-cpp module uses DynamicUser=true, which
  # creates a per-boot UID under /var/lib/private. That's incompatible with
  # impermanence bind-mounting /var/lib/llama-cpp directly. Force a stable
  # system user so the bind mount works (same pattern as ollama.nix did).
  systemd.services.llama-cpp.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "llama-cpp";
    Group = "llama-cpp";
    StateDirectory = lib.mkForce "llama-cpp";
    CacheDirectory = lib.mkForce "llama-cpp";
  };

  users.users.llama-cpp = {
    isSystemUser = true;
    group = "llama-cpp";
    home = "/var/lib/llama-cpp";
  };
  users.groups.llama-cpp = { };

  # Ensure both state and cache dirs exist with the right ownership before
  # the unit starts (ProtectSystem=strict + ReadWritePaths needs them to
  # exist for mount namespacing).
  systemd.tmpfiles.rules = [
    "d /var/lib/llama-cpp   0750 llama-cpp llama-cpp -"
    "d /var/cache/llama-cpp 0750 llama-cpp llama-cpp -"
  ];

  # Allow access from Tailscale overlay and LAN.
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];
  networking.firewall.allowedTCPPorts = [ c.port ];
}
